// 极简 socket 兼容层：Windows(Winsock) / POSIX 通用。仅供本地测试工具使用。
//
// 为什么要它：本地拟真台需要在**真实 TCP** 上跑（分段/粘包/超时只有真链路才出现），
// 而 Windows 用 winsock（要 -lws2_32）、Linux/macOS 用 BSD socket，接口名不同。
// 这里把差异收敛掉，让 tools/mock_meter.c 与 Tests/CTests/local_e2e.c 共用。
//
// 已在本机实测（TDM-GCC）：bind 127.0.0.1 + listen + accept 正常、**不弹防火墙**；
// 用 Send 分段发送时客户端确实收到 2/2/... 分片 → 能精确复现"长帧被 TCP 拆开"。
#ifndef SOCK_COMPAT_H
#define SOCK_COMPAT_H

#ifdef _WIN32
  #include <winsock2.h>
  #include <ws2tcpip.h>
  typedef SOCKET sock_t;
  #define SOCK_INVALID INVALID_SOCKET
  #define sock_close   closesocket
  #define sock_len_t   int
  static int sock_init(void) { WSADATA w; return (int)WSAStartup(MAKEWORD(2, 2), &w); }
  static void sock_fini(void) { WSACleanup(); }
  // 两个测试工具只会用到其中一个，未使用者不报警（-Wall 下保持干净）
  static void sock_sleep_ms(int ms) __attribute__((unused));
  static void sock_sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
  #include <sys/socket.h>
  #include <netinet/in.h>
  #include <arpa/inet.h>
  #include <unistd.h>
  #include <time.h>
  typedef int sock_t;
  #define SOCK_INVALID (-1)
  #define sock_close   close
  #define sock_len_t   socklen_t
  static int sock_init(void) { return 0; }
  static void sock_fini(void) {}
  static void sock_sleep_ms(int ms) __attribute__((unused));
  static void sock_sleep_ms(int ms)
  {
      struct timespec ts;
      ts.tv_sec = ms / 1000;
      ts.tv_nsec = (long)(ms % 1000) * 1000000L;
      nanosleep(&ts, NULL);
  }
#endif

// 带超时的“可读”等待：返回 1 = 有数据可读，0 = 超时。用于让 recv 回调可返回“无数据”，
// 与 App 侧 receive(max:) 超时返回 nil 的行为保持一致（否则测试可能永久阻塞）。
static int sock_wait_readable(sock_t fd, int ms)
{
    struct timeval tv;
    fd_set r;
    FD_ZERO(&r);
    FD_SET(fd, &r);
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
#ifdef _WIN32
    return select(0, &r, NULL, NULL, &tv) > 0;
#else
    return select(fd + 1, &r, NULL, NULL, &tv) > 0;
#endif
}

#endif // SOCK_COMPAT_H
