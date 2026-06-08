
#include "../common/protocol.hpp"
#include <iostream>
#include <thread>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

// Windows側からのTCP接続を受け付け、WSL側Unix socketへ中継する

static const char* WSL_SOCKET_PATH = "/tmp/tinker-bridge.sock";
static const int   TCP_PORT        = 7070;

// WSL側に接続
int connect_to_wsl()
{
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0)
  {
    perror("socket(unix)");
    return -1;
  }

  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, WSL_SOCKET_PATH, sizeof(addr.sun_path) - 1);

  if (connect(fd, (sockaddr*)&addr, sizeof(addr)) < 0)
  {
    perror("connect(unix)");
    close(fd);
    return -1;
  }
  return fd;
}

// TCP client <-> Unix socket 双方向中継
void relay(int tcp_fd, int unix_fd)
{
  // tcp -> unix
  auto fwd = [](int from, int to, const char* label) {
    char buf[4096]{};
    while (true)
    {
      ssize_t n = read(from, buf, sizeof(buf));
      if (n <= 0)
      {
        std::cerr << "[bridge] " << label << " closed\n";
        shutdown(to, SHUT_WR);
        break;
      }
      size_t sent = 0;
      while (sent < (size_t)n)
      {
        ssize_t w = write(to, buf + sent, n - sent);
        if (w <= 0)
        {
          break;
        }
        sent += w;
      }
    }
  };

  std::thread t1(fwd, tcp_fd, unix_fd, "tcp->unix");
  std::thread t2(fwd, unix_fd, tcp_fd, "unix->tcp");
  t1.join();
  t2.join();

  close(tcp_fd);
  close(unix_fd);
}

int main()
{
  // TCP listen
  int server_fd = socket(AF_INET, SOCK_STREAM, 0);
  if (server_fd < 0)
  {
    perror("socket(tcp)");
    return 1;
  }

  int opt = 1;
  setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

  sockaddr_in addr{};
  addr.sin_family      = AF_INET;
  addr.sin_addr.s_addr = INADDR_ANY;
  addr.sin_port        = htons(TCP_PORT);

  if (bind(server_fd, (sockaddr*)&addr, sizeof(addr)) < 0)
  {
    perror("bind"); return 1;
  }

  if (listen(server_fd, 8) < 0)
  {
    perror("listen"); return 1;
  }

  std::cerr << "[bridge] TCP listening on :" << TCP_PORT << "\n";
  std::cerr << "[bridge] forwarding to " << WSL_SOCKET_PATH << "\n";

  while (true)
  {
    int tcp_fd = accept(server_fd, nullptr, nullptr);
    if (tcp_fd < 0)
    {
      perror("accept");
      continue;
    }

    int unix_fd = connect_to_wsl();
    if (unix_fd < 0)
    {
      std::cerr << "[bridge] cannot reach WSL server\n";
      close(tcp_fd);
      continue;
    }

    std::cerr << "[bridge] relay started\n";
    std::thread(relay, tcp_fd, unix_fd).detach();
  }
}


