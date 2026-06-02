#include "../common/protocol.hpp"
#include <iostream>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <csignal>
#include <thread>

namespace fs = std::filesystem;
using namespace tinker;

static const char* SOCKET_PATH = "/tmp/tinker-bridge.sock";

// ---- ファイル操作 ----

Response handle_read(const Request& req) {
    Response res;
    res.id = req.id;
    std::ifstream f(req.path, std::ios::binary);
    if (!f) {
        res.ok    = false;
        res.error = "cannot open: " + req.path;
        return res;
    }
    std::ostringstream ss;
    ss << f.rdbuf();
    res.ok      = true;
    res.content = ss.str();
    return res;
}

Response handle_write(const Request& req) {
    Response res;
    res.id = req.id;
    std::ofstream f(req.path, std::ios::binary | std::ios::trunc);
    if (!f) {
        res.ok    = false;
        res.error = "cannot write: " + req.path;
        return res;
    }
    f << req.content;
    res.ok = true;
    return res;
}

Response handle_list(const Request& req) {
    Response res;
    res.id = req.id;
    std::error_code ec;
    if (!fs::is_directory(req.path, ec)) {
        res.ok    = false;
        res.error = "not a directory: " + req.path;
        return res;
    }
    json entries = json::array();
    for (auto& entry : fs::directory_iterator(req.path, ec)) {
        json e;
        e["name"] = entry.path().filename().string();
        e["type"] = entry.is_directory() ? "dir" : "file";
        entries.push_back(e);
    }
    res.ok      = true;
    res.content = entries.dump();
    return res;
}

// ---- クライアント1件を処理するスレッド ----

void handle_client(int client_fd) {
    std::cerr << "[server] client connected fd=" << client_fd << "\n";
    while (true) {
        std::string line = recv_line(client_fd);
        if (line.empty()) break;

        Request req;
        try {
            req = Request::from_json(json::parse(line));
        } catch (const std::exception& e) {
            std::cerr << "[server] parse error: " << e.what() << "\n";
            break;
        }

        std::cerr << "[server] op=" << req.op << " path=" << req.path << "\n";

        Response res;
        if      (req.op == "read")  res = handle_read(req);
        else if (req.op == "write") res = handle_write(req);
        else if (req.op == "list")  res = handle_list(req);
        else {
            res.id    = req.id;
            res.ok    = false;
            res.error = "unknown op: " + req.op;
        }

        send_line(client_fd, res.to_json().dump());
    }
    std::cerr << "[server] client disconnected fd=" << client_fd << "\n";
    close(client_fd);
}

// ---- メイン ----

int main() {
    // 既存ソケットファイルを削除
    unlink(SOCKET_PATH);

    int server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket"); return 1; }

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (bind(server_fd, (sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind"); return 1;
    }
    if (listen(server_fd, 8) < 0) {
        perror("listen"); return 1;
    }

    std::cerr << "[server] listening on " << SOCKET_PATH << "\n";

    // Ctrl+C で終了したときソケットを消す
    signal(SIGINT, [](int) { unlink("/tmp/tinker-bridge.sock"); exit(0); });

    while (true) {
        int client_fd = accept(server_fd, nullptr, nullptr);
        if (client_fd < 0) { perror("accept"); continue; }
        std::thread(handle_client, client_fd).detach();
    }
}
