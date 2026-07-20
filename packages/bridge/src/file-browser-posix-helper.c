#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

#ifndef O_NOFOLLOW
#error "The file browser helper requires O_NOFOLLOW"
#endif

#ifndef AT_SYMLINK_NOFOLLOW
#error "The file browser helper requires AT_SYMLINK_NOFOLLOW"
#endif

#define ROOT_FD 3
#define MAX_CANONICAL_RELATIVE_BYTES 4096U
#define MAX_STAT_ITEMS 200U
#define MAX_PROTOCOL_LINE_BYTES 32768U
#define HARD_MAX_DIRECTORY_ENTRIES 100000U
#define HARD_MAX_DIRECTORY_NAME_BYTES (16U * 1024U * 1024U)

struct name_entry {
  char *value;
  size_t length;
};

static void print_error(const char *code) {
  printf("ERR\t%s\n", code);
}

static const char *errno_code(int value) {
  switch (value) {
    case ENOENT:
    case ENOTDIR:
      return "not_found";
    case EACCES:
    case EPERM:
      return "permission_denied";
    case ELOOP:
      return "invalid_symlink";
    default:
      return "file_unreadable";
  }
}

static int parse_uintmax(const char *text, uintmax_t *value) {
  char *end = NULL;
  errno = 0;
  uintmax_t parsed = strtoumax(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0') return -1;
  *value = parsed;
  return 0;
}

static int parse_size(const char *text, size_t maximum, size_t *value) {
  uintmax_t parsed = 0;
  if (parse_uintmax(text, &parsed) != 0 || parsed > maximum) return -1;
  *value = (size_t)parsed;
  return 0;
}

static int hex_value(char value) {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  if (value >= 'A' && value <= 'F') return value - 'A' + 10;
  return -1;
}

static int decode_hex_token(
    const char *token,
    unsigned char **output,
    size_t *output_length) {
  if (strcmp(token, "~") == 0) {
    unsigned char *empty = calloc(1, 1);
    if (empty == NULL) return -1;
    *output = empty;
    *output_length = 0;
    return 0;
  }
  size_t token_length = strlen(token);
  if (token_length == 0 || (token_length % 2) != 0 ||
      token_length / 2 > MAX_CANONICAL_RELATIVE_BYTES) {
    return -1;
  }
  size_t length = token_length / 2;
  unsigned char *decoded = malloc(length + 1);
  if (decoded == NULL) return -1;
  for (size_t index = 0; index < length; index += 1) {
    int high = hex_value(token[index * 2]);
    int low = hex_value(token[index * 2 + 1]);
    if (high < 0 || low < 0) {
      free(decoded);
      return -1;
    }
    decoded[index] = (unsigned char)((high << 4) | low);
    if (decoded[index] == '\0') {
      free(decoded);
      return -1;
    }
  }
  decoded[length] = '\0';
  *output = decoded;
  *output_length = length;
  return 0;
}

static void print_hex(const unsigned char *value, size_t length) {
  static const char digits[] = "0123456789abcdef";
  if (length == 0) {
    putchar('~');
    return;
  }
  for (size_t index = 0; index < length; index += 1) {
    unsigned char byte = value[index];
    putchar(digits[byte >> 4]);
    putchar(digits[byte & 0x0f]);
  }
}

static int is_valid_utf8(const unsigned char *value, size_t length) {
  size_t index = 0;
  while (index < length) {
    unsigned char first = value[index++];
    if (first <= 0x7f) continue;
    size_t continuation = 0;
    uint32_t scalar = 0;
    if (first >= 0xc2 && first <= 0xdf) {
      continuation = 1;
      scalar = first & 0x1fU;
    } else if (first >= 0xe0 && first <= 0xef) {
      continuation = 2;
      scalar = first & 0x0fU;
    } else if (first >= 0xf0 && first <= 0xf4) {
      continuation = 3;
      scalar = first & 0x07U;
    } else {
      return 0;
    }
    if (index + continuation > length) return 0;
    for (size_t offset = 0; offset < continuation; offset += 1) {
      unsigned char next = value[index++];
      if ((next & 0xc0U) != 0x80U) return 0;
      scalar = (scalar << 6) | (next & 0x3fU);
    }
    if ((continuation == 2 && scalar < 0x800U) ||
        (continuation == 3 && scalar < 0x10000U) ||
        scalar > 0x10ffffU ||
        (scalar >= 0xd800U && scalar <= 0xdfffU)) {
      return 0;
    }
  }
  return 1;
}

static int valid_relative_path(const char *path) {
  if (path == NULL) return 0;
  size_t length = strlen(path);
  if (length > MAX_CANONICAL_RELATIVE_BYTES || path[0] == '/') return 0;
  if (length == 0) return 1;
  const char *segment = path;
  for (size_t index = 0; index <= length; index += 1) {
    char value = path[index];
    if (value == '\\') return 0;
    if (value != '/' && value != '\0') continue;
    size_t segment_length = (size_t)(&path[index] - segment);
    if (segment_length == 0 ||
        (segment_length == 1 && segment[0] == '.') ||
        (segment_length == 2 && segment[0] == '.' && segment[1] == '.')) {
      return 0;
    }
    segment = &path[index + 1];
  }
  return 1;
}

static int valid_absolute_path(const char *path) {
  if (path == NULL || path[0] != '/') return 0;
  size_t length = strlen(path);
  if (length == 0 || length > MAX_CANONICAL_RELATIVE_BYTES) return 0;
  if (length == 1) return 1;
  const char *segment = path + 1;
  for (size_t index = 1; index <= length; index += 1) {
    char value = path[index];
    if (value != '/' && value != '\0') continue;
    size_t segment_length = (size_t)(&path[index] - segment);
    if (segment_length == 0 ||
        (segment_length == 1 && segment[0] == '.') ||
        (segment_length == 2 && segment[0] == '.' && segment[1] == '.')) {
      return 0;
    }
    segment = &path[index + 1];
  }
  return 1;
}

static int valid_leaf_name(const char *name) {
  if (name == NULL || name[0] == '\0' || strchr(name, '/') != NULL ||
      strchr(name, '\\') != NULL || strcmp(name, ".") == 0 ||
      strcmp(name, "..") == 0) {
    return 0;
  }
  return strlen(name) <= MAX_CANONICAL_RELATIVE_BYTES;
}

static int duplicate_cloexec(int fd) {
#ifdef F_DUPFD_CLOEXEC
  int cloexec_duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 4);
  if (cloexec_duplicate >= 0) return cloexec_duplicate;
  if (errno != EINVAL) return -1;
#endif
  int duplicated = dup(fd);
  if (duplicated < 0) return -1;
  if (fcntl(duplicated, F_SETFD, FD_CLOEXEC) != 0) {
    int saved = errno;
    close(duplicated);
    errno = saved;
    return -1;
  }
  return duplicated;
}

static int open_directory_beneath(int root_fd, const char *relative_path) {
  if (!valid_relative_path(relative_path)) {
    errno = EINVAL;
    return -1;
  }
  int current = duplicate_cloexec(root_fd);
  if (current < 0 || relative_path[0] == '\0') return current;
  char *copy = strdup(relative_path);
  if (copy == NULL) {
    close(current);
    errno = ENOMEM;
    return -1;
  }
  char *save = NULL;
  for (char *segment = strtok_r(copy, "/", &save); segment != NULL;
       segment = strtok_r(NULL, "/", &save)) {
    int next = openat(
        current,
        segment,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (next < 0) {
      int saved = errno;
      close(current);
      free(copy);
      errno = saved;
      return -1;
    }
    close(current);
    current = next;
  }
  free(copy);
  return current;
}

static int open_absolute_directory_nofollow(const char *absolute_path) {
  if (!valid_absolute_path(absolute_path)) {
    errno = EINVAL;
    return -1;
  }
  int current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (current < 0 || absolute_path[1] == '\0') return current;
  char *copy = strdup(absolute_path + 1);
  if (copy == NULL) {
    close(current);
    errno = ENOMEM;
    return -1;
  }
  char *save = NULL;
  for (char *segment = strtok_r(copy, "/", &save); segment != NULL;
       segment = strtok_r(NULL, "/", &save)) {
    int next = openat(
        current,
        segment,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (next < 0) {
      int saved = errno;
      close(current);
      free(copy);
      errno = saved;
      return -1;
    }
    close(current);
    current = next;
  }
  free(copy);
  return current;
}

static int split_parent_leaf(
    const char *relative_path,
    char **parent,
    char **leaf) {
  if (!valid_relative_path(relative_path) || relative_path[0] == '\0') return -1;
  char *copy = strdup(relative_path);
  if (copy == NULL) return -1;
  char *slash = strrchr(copy, '/');
  if (slash == NULL) {
    *parent = strdup("");
    *leaf = copy;
  } else {
    *slash = '\0';
    *parent = strdup(copy);
    *leaf = strdup(slash + 1);
    free(copy);
  }
  if (*parent == NULL || *leaf == NULL || !valid_leaf_name(*leaf)) {
    free(*parent);
    free(*leaf);
    *parent = NULL;
    *leaf = NULL;
    return -1;
  }
  return 0;
}

static int stat_canonical(int root_fd, const char *relative_path, struct stat *output) {
  if (relative_path[0] == '\0') return fstat(root_fd, output);
  char *parent = NULL;
  char *leaf = NULL;
  if (split_parent_leaf(relative_path, &parent, &leaf) != 0) {
    errno = EINVAL;
    return -1;
  }
  int parent_fd = open_directory_beneath(root_fd, parent);
  free(parent);
  if (parent_fd < 0) {
    free(leaf);
    return -1;
  }
  int result = fstatat(parent_fd, leaf, output, AT_SYMLINK_NOFOLLOW);
  int saved = errno;
  close(parent_fd);
  free(leaf);
  errno = saved;
  if (result == 0 && S_ISLNK(output->st_mode)) {
    errno = ELOOP;
    return -1;
  }
  return result;
}

static int root_is_expected(uintmax_t expected_dev, uintmax_t expected_ino) {
  struct stat root;
  if (fstat(ROOT_FD, &root) != 0 || !S_ISDIR(root.st_mode)) return 0;
  return (uintmax_t)root.st_dev == expected_dev &&
         (uintmax_t)root.st_ino == expected_ino;
}

#ifdef __APPLE__
static intmax_t stat_mtime_sec(const struct stat *value) {
  return (intmax_t)value->st_mtimespec.tv_sec;
}
static long stat_mtime_nsec(const struct stat *value) {
  return value->st_mtimespec.tv_nsec;
}
static intmax_t stat_ctime_sec(const struct stat *value) {
  return (intmax_t)value->st_ctimespec.tv_sec;
}
static long stat_ctime_nsec(const struct stat *value) {
  return value->st_ctimespec.tv_nsec;
}
#else
static intmax_t stat_mtime_sec(const struct stat *value) {
  return (intmax_t)value->st_mtim.tv_sec;
}
static long stat_mtime_nsec(const struct stat *value) {
  return value->st_mtim.tv_nsec;
}
static intmax_t stat_ctime_sec(const struct stat *value) {
  return (intmax_t)value->st_ctim.tv_sec;
}
static long stat_ctime_nsec(const struct stat *value) {
  return value->st_ctim.tv_nsec;
}
#endif

static int same_stats(const struct stat *left, const struct stat *right) {
  return left->st_dev == right->st_dev && left->st_ino == right->st_ino &&
         left->st_mode == right->st_mode && left->st_size == right->st_size &&
         stat_mtime_sec(left) == stat_mtime_sec(right) &&
         stat_mtime_nsec(left) == stat_mtime_nsec(right) &&
         stat_ctime_sec(left) == stat_ctime_sec(right) &&
         stat_ctime_nsec(left) == stat_ctime_nsec(right);
}

static char stat_kind(const struct stat *value) {
  if (S_ISREG(value->st_mode)) return 'f';
  if (S_ISDIR(value->st_mode)) return 'd';
  if (S_ISLNK(value->st_mode)) return 'l';
  return 'o';
}

static void print_stat_fields(const struct stat *value) {
  printf(
      "%c\t%ju\t%ju\t%ju\t%jd\t%jd\t%ld\t%jd\t%ld",
      stat_kind(value),
      (uintmax_t)value->st_dev,
      (uintmax_t)value->st_ino,
      (uintmax_t)value->st_mode,
      (intmax_t)value->st_size,
      stat_mtime_sec(value),
      stat_mtime_nsec(value),
      stat_ctime_sec(value),
      stat_ctime_nsec(value));
}

static uint64_t hash_bytes(uint64_t hash, const void *bytes, size_t length) {
  const unsigned char *value = bytes;
  for (size_t index = 0; index < length; index += 1) {
    hash ^= value[index];
    hash *= UINT64_C(1099511628211);
  }
  return hash;
}

static uint64_t hash_stat(uint64_t hash, const struct stat *value) {
  hash = hash_bytes(hash, &value->st_dev, sizeof(value->st_dev));
  hash = hash_bytes(hash, &value->st_ino, sizeof(value->st_ino));
  hash = hash_bytes(hash, &value->st_mode, sizeof(value->st_mode));
  hash = hash_bytes(hash, &value->st_size, sizeof(value->st_size));
  intmax_t mtime_sec = stat_mtime_sec(value);
  long mtime_nsec = stat_mtime_nsec(value);
  intmax_t ctime_sec = stat_ctime_sec(value);
  long ctime_nsec = stat_ctime_nsec(value);
  hash = hash_bytes(hash, &mtime_sec, sizeof(mtime_sec));
  hash = hash_bytes(hash, &mtime_nsec, sizeof(mtime_nsec));
  hash = hash_bytes(hash, &ctime_sec, sizeof(ctime_sec));
  return hash_bytes(hash, &ctime_nsec, sizeof(ctime_nsec));
}

static int compare_name_entries(const void *left_value, const void *right_value) {
  const struct name_entry *left = left_value;
  const struct name_entry *right = right_value;
  size_t common = left->length < right->length ? left->length : right->length;
  int compared = memcmp(left->value, right->value, common);
  if (compared != 0) return compared;
  if (left->length < right->length) return -1;
  if (left->length > right->length) return 1;
  return 0;
}

static void free_names(struct name_entry *names, size_t count) {
  if (names == NULL) return;
  for (size_t index = 0; index < count; index += 1) free(names[index].value);
  free(names);
}

static int run_list(int argc, char **argv) {
  if (argc != 10) {
    print_error("invalid_request");
    return 2;
  }
  uintmax_t expected_dev = 0;
  uintmax_t expected_ino = 0;
  size_t page_size = 0;
  size_t start_index = 0;
  size_t show_hidden = 0;
  size_t max_entries = 0;
  size_t max_name_bytes = 0;
  if (parse_uintmax(argv[2], &expected_dev) != 0 ||
      parse_uintmax(argv[3], &expected_ino) != 0 ||
      parse_size(argv[5], 200U, &page_size) != 0 || page_size == 0 ||
      parse_size(argv[6], HARD_MAX_DIRECTORY_ENTRIES, &start_index) != 0 ||
      parse_size(argv[7], 1U, &show_hidden) != 0 ||
      parse_size(argv[8], HARD_MAX_DIRECTORY_ENTRIES, &max_entries) != 0 ||
      max_entries == 0 ||
      parse_size(argv[9], HARD_MAX_DIRECTORY_NAME_BYTES, &max_name_bytes) != 0 ||
      max_name_bytes == 0 || !root_is_expected(expected_dev, expected_ino)) {
    print_error("root_changed");
    return 3;
  }
  unsigned char *decoded_path = NULL;
  size_t decoded_length = 0;
  if (decode_hex_token(argv[4], &decoded_path, &decoded_length) != 0 ||
      !is_valid_utf8(decoded_path, decoded_length) ||
      !valid_relative_path((const char *)decoded_path)) {
    free(decoded_path);
    print_error("invalid_relative_path");
    return 2;
  }
  int directory_fd = open_directory_beneath(ROOT_FD, (const char *)decoded_path);
  free(decoded_path);
  if (directory_fd < 0) {
    print_error(errno_code(errno));
    return 4;
  }
  DIR *directory = fdopendir(directory_fd);
  if (directory == NULL) {
    int saved = errno;
    close(directory_fd);
    print_error(errno_code(saved));
    return 4;
  }
  struct stat before;
  struct stat after;
  if (fstat(dirfd(directory), &before) != 0 || !S_ISDIR(before.st_mode)) {
    closedir(directory);
    print_error("not_directory");
    return 4;
  }

  struct name_entry *names = NULL;
  size_t name_count = 0;
  size_t name_capacity = 0;
  size_t observed_entries = 0;
  size_t observed_name_bytes = 0;
  errno = 0;
  struct dirent *entry = NULL;
  while ((entry = readdir(directory)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    size_t length = strlen(entry->d_name);
    observed_entries += 1;
    if (length > SIZE_MAX - observed_name_bytes) {
      errno = EOVERFLOW;
      break;
    }
    observed_name_bytes += length;
    if (observed_entries > max_entries || observed_name_bytes > max_name_bytes) {
      errno = EFBIG;
      break;
    }
    if ((!show_hidden && entry->d_name[0] == '.') ||
        !valid_leaf_name(entry->d_name) ||
        !is_valid_utf8((const unsigned char *)entry->d_name, length)) {
      continue;
    }
    if (name_count == name_capacity) {
      size_t next_capacity = name_capacity == 0 ? 128U : name_capacity * 2U;
      if (next_capacity > max_entries) next_capacity = max_entries;
      struct name_entry *grown = realloc(names, next_capacity * sizeof(*names));
      if (grown == NULL) {
        errno = ENOMEM;
        break;
      }
      names = grown;
      name_capacity = next_capacity;
    }
    names[name_count].value = malloc(length + 1);
    if (names[name_count].value == NULL) {
      errno = ENOMEM;
      break;
    }
    memcpy(names[name_count].value, entry->d_name, length + 1);
    names[name_count].length = length;
    name_count += 1;
  }
  int read_error = errno;
  if (fstat(dirfd(directory), &after) != 0 && read_error == 0) read_error = errno;
  closedir(directory);
  if (read_error != 0) {
    free_names(names, name_count);
    print_error(read_error == EFBIG ? "directory_too_large" : errno_code(read_error));
    return 5;
  }
  if (!same_stats(&before, &after)) {
    free_names(names, name_count);
    print_error("directory_changed");
    return 5;
  }
  qsort(names, name_count, sizeof(*names), compare_name_entries);
  if (start_index > name_count) {
    free_names(names, name_count);
    print_error("directory_changed");
    return 5;
  }
  uint64_t revision = hash_stat(UINT64_C(1469598103934665603), &after);
  for (size_t index = 0; index < name_count; index += 1) {
    revision = hash_bytes(revision, names[index].value, names[index].length);
    const unsigned char separator = 0;
    revision = hash_bytes(revision, &separator, 1);
  }
  size_t end = start_index + page_size;
  if (end < start_index || end > name_count) end = name_count;
  printf("OK\t");
  print_stat_fields(&after);
  printf("\t%016" PRIx64 "\t%zu\t", revision, name_count);
  if (end < name_count) printf("%zu", end);
  else putchar('-');
  putchar('\n');
  for (size_t index = start_index; index < end; index += 1) {
    printf("N\t");
    print_hex((const unsigned char *)names[index].value, names[index].length);
    putchar('\n');
  }
  free_names(names, name_count);
  return 0;
}

static int run_inspect_root(int argc, char **argv) {
  if (argc != 3) {
    print_error("invalid_request");
    return 2;
  }
  unsigned char *decoded_path = NULL;
  size_t decoded_length = 0;
  if (decode_hex_token(argv[2], &decoded_path, &decoded_length) != 0 ||
      !is_valid_utf8(decoded_path, decoded_length) ||
      !valid_absolute_path((const char *)decoded_path)) {
    free(decoded_path);
    print_error("invalid_root");
    return 2;
  }
  int root_fd = open_absolute_directory_nofollow((const char *)decoded_path);
  free(decoded_path);
  if (root_fd < 0) {
    print_error(errno_code(errno));
    return 4;
  }
  struct stat root;
  if (fstat(root_fd, &root) != 0 || !S_ISDIR(root.st_mode)) {
    int saved = errno;
    close(root_fd);
    print_error(errno_code(saved));
    return 4;
  }
  close(root_fd);
  printf("OK\t%ju\t%ju\n", (uintmax_t)root.st_dev, (uintmax_t)root.st_ino);
  return 0;
}

static int stat_source(
    int root_fd,
    const char *parent,
    const char *name,
    int has_expected_parent,
    uintmax_t expected_parent_dev,
    uintmax_t expected_parent_ino,
    struct stat *output) {
  if (strcmp(name, "-") == 0) {
    if (parent[0] != '\0') {
      errno = EINVAL;
      return -1;
    }
    if (fstat(root_fd, output) != 0) return -1;
    if (has_expected_parent &&
        ((uintmax_t)output->st_dev != expected_parent_dev ||
         (uintmax_t)output->st_ino != expected_parent_ino)) {
      return -2;
    }
    return 0;
  }
  if (!valid_relative_path(parent) || !valid_leaf_name(name)) {
    errno = EINVAL;
    return -1;
  }
  int parent_fd = open_directory_beneath(root_fd, parent);
  if (parent_fd < 0) return has_expected_parent ? -2 : -1;
  if (has_expected_parent) {
    struct stat parent_stats;
    if (fstat(parent_fd, &parent_stats) != 0) {
      int saved = errno;
      close(parent_fd);
      errno = saved;
      return -1;
    }
    if ((uintmax_t)parent_stats.st_dev != expected_parent_dev ||
        (uintmax_t)parent_stats.st_ino != expected_parent_ino) {
      close(parent_fd);
      return -2;
    }
  }
  int result = fstatat(parent_fd, name, output, AT_SYMLINK_NOFOLLOW);
  int saved = errno;
  close(parent_fd);
  errno = saved;
  return result;
}

static int split_tabs(char *line, char **fields, size_t expected) {
  size_t count = 0;
  char *cursor = line;
  while (count < expected) {
    fields[count++] = cursor;
    char *tab = strchr(cursor, '\t');
    if (tab == NULL) break;
    *tab = '\0';
    cursor = tab + 1;
  }
  return count == expected && strchr(fields[expected - 1], '\t') == NULL;
}

static int run_stat(int argc, char **argv) {
  if (argc != 5) {
    print_error("invalid_request");
    return 2;
  }
  uintmax_t expected_dev = 0;
  uintmax_t expected_ino = 0;
  size_t max_items = 0;
  if (parse_uintmax(argv[2], &expected_dev) != 0 ||
      parse_uintmax(argv[3], &expected_ino) != 0 ||
      parse_size(argv[4], MAX_STAT_ITEMS, &max_items) != 0 ||
      max_items == 0 || !root_is_expected(expected_dev, expected_ino)) {
    print_error("root_changed");
    return 3;
  }
  char *line = NULL;
  size_t capacity = 0;
  size_t count = 0;
  ssize_t length = 0;
  while ((length = getline(&line, &capacity, stdin)) >= 0) {
    if ((size_t)length > MAX_PROTOCOL_LINE_BYTES || ++count > max_items) {
      free(line);
      print_error("too_many_items");
      return 2;
    }
    while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r')) {
      line[--length] = '\0';
    }
    char *fields[6];
    if (!split_tabs(line, fields, 6)) {
      free(line);
      print_error("invalid_request");
      return 2;
    }
    size_t id = 0;
    if (parse_size(fields[0], max_items - 1, &id) != 0) {
      free(line);
      print_error("invalid_request");
      return 2;
    }
    unsigned char *parent = NULL;
    unsigned char *name = NULL;
    unsigned char *target = NULL;
    size_t parent_length = 0;
    size_t name_length = 0;
    size_t target_length = 0;
    int name_absent = strcmp(fields[2], "-") == 0;
    int target_absent = strcmp(fields[3], "-") == 0;
    int parent_identity_absent =
        strcmp(fields[4], "-") == 0 && strcmp(fields[5], "-") == 0;
    uintmax_t expected_parent_dev = 0;
    uintmax_t expected_parent_ino = 0;
    if (decode_hex_token(fields[1], &parent, &parent_length) != 0 ||
        (!name_absent && decode_hex_token(fields[2], &name, &name_length) != 0) ||
        (!target_absent && decode_hex_token(fields[3], &target, &target_length) != 0) ||
        ((!parent_identity_absent) &&
         (strcmp(fields[4], "-") == 0 || strcmp(fields[5], "-") == 0 ||
          parse_uintmax(fields[4], &expected_parent_dev) != 0 ||
          parse_uintmax(fields[5], &expected_parent_ino) != 0)) ||
        !is_valid_utf8(parent, parent_length) ||
        (!name_absent && !is_valid_utf8(name, name_length)) ||
        (!target_absent && !is_valid_utf8(target, target_length))) {
      free(parent);
      free(name);
      free(target);
      printf("E\t%zu\tinvalid_relative_path\n", id);
      continue;
    }
    struct stat source_stats;
    int source_result = stat_source(
            ROOT_FD,
            (const char *)parent,
            name_absent ? "-" : (const char *)name,
            !parent_identity_absent,
            expected_parent_dev,
            expected_parent_ino,
            &source_stats);
    if (source_result != 0) {
      printf(
          "E\t%zu\t%s\n",
          id,
          source_result == -2 ? "directory_changed" : errno_code(errno));
      free(parent);
      free(name);
      free(target);
      continue;
    }
    struct stat target_stats;
    int has_target = !target_absent;
    if (has_target &&
        stat_canonical(ROOT_FD, (const char *)target, &target_stats) != 0) {
      printf("E\t%zu\t%s\n", id, errno_code(errno));
      free(parent);
      free(name);
      free(target);
      continue;
    }
    printf("S\t%zu\t", id);
    print_stat_fields(&source_stats);
    if (has_target) {
      printf("\tT\t");
      print_stat_fields(&target_stats);
    } else {
      printf("\t-");
    }
    putchar('\n');
    free(parent);
    free(name);
    free(target);
  }
  free(line);
  if (ferror(stdin)) {
    print_error("invalid_request");
    return 2;
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "version") == 0) {
    printf("OK\t3\n");
    return 0;
  }
  if (argc >= 2 && strcmp(argv[1], "inspect-root") == 0) {
    return run_inspect_root(argc, argv);
  }
  if (argc >= 2 && strcmp(argv[1], "list") == 0) return run_list(argc, argv);
  if (argc >= 2 && strcmp(argv[1], "stat") == 0) return run_stat(argc, argv);
  print_error("invalid_request");
  return 2;
}
