/* Minimal HTTPS server for the forge-runtime-ca-trust test.
 * Serves files from a directory tree over TLS on 127.0.0.1:<port>.
 * Handles git smart HTTP for info/refs endpoints.
 * Usage: tls-test-server <docroot> <cert> <key> <port>
 * Prints READY to stdout when listening; serves until SIGTERM/SIGINT. */
#include <arpa/inet.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <openssl/ssl.h>
#include <openssl/err.h>

static volatile sig_atomic_t running = 1;
static void stop(int sig) { (void)sig; running = 0; }

typedef struct { char *data; size_t len; } Buf;

/* Run a command and return its stdout as a malloc'd buffer with length. */
static Buf run_cmd(const char *cmd) {
    Buf b = {NULL, 0};
    FILE *p = popen(cmd, "r");
    if (!p) return b;
    size_t cap = 4096, len = 0;
    char *buf = malloc(cap);
    if (!buf) { pclose(p); return b; }
    size_t n;
    while ((n = fread(buf + len, 1, cap - len - 1, p)) > 0) {
        len += n;
        if (len + 1 >= cap) { cap *= 2; buf = realloc(buf, cap); }
    }
    pclose(p);
    b.data = buf;
    b.len = len;
    return b;
}

static void send_bytes(SSL *ssl, const void *data, size_t len) {
    const char *p = (const char *)data;
    while (len > 0) {
        int n = SSL_write(ssl, p, len);
        if (n <= 0) break;
        p += n; len -= n;
    }
}

static void send_str(SSL *ssl, const char *s) { send_bytes(ssl, s, strlen(s)); }

static void handle_client(SSL *ssl, const char *docroot) {
    char buf[8192];
    int n = SSL_read(ssl, buf, sizeof(buf) - 1);
    if (n <= 0) return;
    buf[n] = '\0';

    if (strncmp(buf, "GET ", 4) != 0) {
        send_str(ssl, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n");
        return;
    }

    /* Parse path and query string */
    char path[2048], version[16];
    if (sscanf(buf + 4, "%2047s %15s", path, version) != 2) {
        send_str(ssl, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
        return;
    }

    /* Strip query string from path for file lookup */
    char clean_path[2048];
    strncpy(clean_path, path, sizeof(clean_path) - 1);
    clean_path[sizeof(clean_path) - 1] = '\0';
    char *qmark = strchr(clean_path, '?');
    if (qmark) *qmark = '\0';

    /* Check for git smart HTTP: info/refs?service=git-upload-pack */
    char *query = strchr(path, '?');
    if (query) query++;
    if (strstr(clean_path, "/info/refs") && query && strstr(query, "service=git-upload-pack")) {
        /* Extract repo path: everything before /info/refs */
        char repo_path[2048];
        size_t plen = strlen(clean_path);
        size_t suffix_len = strlen("/info/refs");
        if (plen > suffix_len) {
            strncpy(repo_path, clean_path, plen - suffix_len);
            repo_path[plen - suffix_len] = '\0';
        } else {
            strcpy(repo_path, ".");
        }

        /* Build the git repo filesystem path */
        char git_dir[4096];
        snprintf(git_dir, sizeof(git_dir), "%s%s", docroot, repo_path);

        /* Run git upload-pack --stateless-rpc --advertise-refs */
        char cmd[8192];
        snprintf(cmd, sizeof(cmd),
            "git upload-pack --stateless-rpc --advertise-refs \"%s\" 2>/dev/null",
            git_dir);
        Buf ads = run_cmd(cmd);

        /* Build response — must not use Content-Length because pkt-line
           contains NUL bytes and we send by length, not by string. */
        const char *hdr = "HTTP/1.1 200 OK\r\n"
                          "Content-Type: application/x-git-upload-pack-advertisement\r\n"
                          "Cache-Control: no-cache\r\n"
                          "Connection: close\r\n"
                          "\r\n";
        send_str(ssl, hdr);

        /* Service header (pkt-line format) */
        static const char svc[] = "001e# service=git-upload-pack\n";
        static const char flush[] = "0000";
        send_bytes(ssl, svc, sizeof(svc) - 1);
        send_bytes(ssl, flush, 4);

        if (ads.data && ads.len > 0) {
            send_bytes(ssl, ads.data, ads.len);
            free(ads.data);
        }
        send_bytes(ssl, flush, 4);
        return;
    }

    /* Default: serve file from docroot */
    char fpath[4096];
    snprintf(fpath, sizeof(fpath), "%s%s", docroot, clean_path);

    FILE *fp = fopen(fpath, "rb");
    if (!fp) {
        send_str(ssl, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
        return;
    }

    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    char header[256];
    int hlen = snprintf(header, sizeof(header),
        "HTTP/1.1 200 OK\r\nContent-Length: %ld\r\nConnection: close\r\n\r\n", sz);
    send_bytes(ssl, header, hlen);

    while ((n = fread(buf, 1, sizeof(buf), fp)) > 0)
        send_bytes(ssl, buf, n);
    fclose(fp);
}

int main(int argc, char *argv[]) {
    if (argc != 5) {
        fprintf(stderr, "Usage: %s <docroot> <cert> <key> <port>\n", argv[0]);
        return 1;
    }
    const char *docroot = argv[1];
    const char *cert    = argv[2];
    const char *keyfile = argv[3];
    int port            = atoi(argv[4]);

    signal(SIGTERM, stop);
    signal(SIGINT,  stop);

    SSL_library_init();
    SSL_load_error_strings();
    OpenSSL_add_all_algorithms();

    const SSL_METHOD *method = TLS_server_method();
    SSL_CTX *ctx = SSL_CTX_new(method);
    if (!ctx) { ERR_print_errors_fp(stderr); return 1; }

    SSL_CTX_use_certificate_file(ctx, cert, SSL_FILETYPE_PEM);
    SSL_CTX_use_PrivateKey_file(ctx, keyfile, SSL_FILETYPE_PEM);

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port   = htons(port),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK)
    };
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); return 1;
    }
    listen(srv, 16);

    printf("READY\n");
    fflush(stdout);

    while (running) {
        int cli = accept(srv, NULL, NULL);
        if (cli < 0) continue;
        SSL *ssl = SSL_new(ctx);
        SSL_set_fd(ssl, cli);
        if (SSL_accept(ssl) <= 0) { SSL_free(ssl); close(cli); continue; }
        handle_client(ssl, docroot);
        SSL_shutdown(ssl);
        SSL_free(ssl);
        close(cli);
    }

    close(srv);
    SSL_CTX_free(ctx);
    EVP_cleanup();
    return 0;
}
