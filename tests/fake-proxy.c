#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int copy_file(const char *source, const char *destination) {
    FILE *input = fopen(source, "rb");
    FILE *output = destination ? fopen(destination, "wb") : NULL;
    char buffer[4096];
    size_t count;
    if (!input || !output) return 1;
    while ((count = fread(buffer, 1, sizeof buffer, input)) > 0) {
        if (fwrite(buffer, 1, count, output) != count) return 1;
    }
    return fclose(input) || fclose(output);
}

int main(int argc, char **argv) {
    const char *config = NULL;
    if (argc > 1 && strcmp(argv[1], "--qbraid-feature") == 0) {
        puts("disable-cloaking-model-list");
        return 0;
    }
    const char *capture = getenv("CAPTURE_PROXY_CONFIG");
    const char *ready = getenv("PROXY_WATCHER_READY");
    FILE *marker;
    int index;
    for (index = 1; index + 1 < argc; index++) {
        if (strcmp(argv[index], "-config") == 0) config = argv[index + 1];
    }
    if (!config) return 2;
    if (capture && copy_file(config, capture)) return 3;
    usleep(400000);
    if (access(config, F_OK) != 0) return 42;
    if (ready) {
        marker = fopen(ready, "wb");
        if (!marker) return 4;
        fputs("ready\n", marker);
        fclose(marker);
    }
    for (;;) sleep(60);
}
