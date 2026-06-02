#pragma once
#include "json.hpp"
#include <string>
#include <unistd.h>

namespace tinker {

using json = nlohmann::json;

// リクエスト
struct Request {
    int         id;
    std::string op;    // "read" | "write" | "list"
    std::string path;
    std::string content; // write時のみ

    static Request from_json(const json& j) {
        Request r;
        r.id      = j.at("id").get<int>();
        r.op      = j.at("op").get<std::string>();
        r.path    = j.at("path").get<std::string>();
        r.content = j.value("content", "");
        return r;
    }

    json to_json() const {
        json j;
        j["id"]   = id;
        j["op"]   = op;
        j["path"] = path;
        if (!content.empty()) j["content"] = content;
        return j;
    }
};

// レスポンス
struct Response {
    int         id;
    bool        ok;
    std::string content; // read/listの結果
    std::string error;   // エラーメッセージ

    json to_json() const {
        json j;
        j["id"]      = id;
        j["ok"]      = ok;
        j["content"] = content;
        if (!error.empty()) j["error"] = error;
        return j;
    }

    static Response from_json(const json& j) {
        Response r;
        r.id      = j.at("id").get<int>();
        r.ok      = j.at("ok").get<bool>();
        r.content = j.value("content", "");
        r.error   = j.value("error", "");
        return r;
    }
};

// ソケットから1行（\n区切り）読む
inline std::string recv_line(int fd) {
    std::string line;
    char c;
    while (true) {
        ssize_t n = ::read(fd, &c, 1);
        if (n <= 0) break;
        if (c == '\n') break;
        line += c;
    }
    return line;
}

// ソケットへ1行送る（\n付き）
inline bool send_line(int fd, const std::string& line) {
    std::string msg = line + "\n";
    size_t sent = 0;
    while (sent < msg.size()) {
        ssize_t n = ::write(fd, msg.c_str() + sent, msg.size() - sent);
        if (n <= 0) return false;
        sent += n;
    }
    return true;
}

} // namespace tinker
