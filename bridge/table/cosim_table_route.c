#define _POSIX_C_SOURCE 200809L

#include "cosim_table_route.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum route_key {
    ROUTE_KEY_RC = 1u << 0,
    ROUTE_KEY_DEVICE = 1u << 1,
    ROUTE_KEY_TARGET = 1u << 2,
    ROUTE_KEY_BAR = 1u << 3,
    ROUTE_KEY_START = 1u << 4,
    ROUTE_KEY_END = 1u << 5,
    ROUTE_KEY_ENTRY_BYTES = 1u << 6,
    ROUTE_KEY_STRIDE_BYTES = 1u << 7,
    ROUTE_KEY_INDEX_BASE = 1u << 8,
    ROUTE_KEY_HANDLER = 1u << 9,
    ROUTE_KEY_OPERATIONS = 1u << 10,
};

#define ROUTE_REQUIRED_KEYS                                                   \
    (ROUTE_KEY_RC | ROUTE_KEY_DEVICE | ROUTE_KEY_TARGET | ROUTE_KEY_BAR |   \
     ROUTE_KEY_START | ROUTE_KEY_END | ROUTE_KEY_ENTRY_BYTES |              \
     ROUTE_KEY_STRIDE_BYTES | ROUTE_KEY_INDEX_BASE | ROUTE_KEY_HANDLER)

typedef struct {
    cosim_table_route_entry_t entry;
    unsigned int seen;
    unsigned int line;
} route_builder_t;

static void route_error(char *error, size_t error_bytes, const char *format,
                        ...)
{
    va_list arguments;

    if (error == NULL || error_bytes == 0) {
        return;
    }
    va_start(arguments, format);
    vsnprintf(error, error_bytes, format, arguments);
    va_end(arguments);
}

static char *trim(char *text)
{
    char *end;

    while (*text == ' ' || *text == '\t' || *text == '\r' || *text == '\n') {
        ++text;
    }
    end = text + strlen(text);
    while (end != text && (end[-1] == ' ' || end[-1] == '\t' ||
                           end[-1] == '\r' || end[-1] == '\n')) {
        --end;
    }
    *end = '\0';
    return text;
}

static int parse_u64(const char *text, uint64_t maximum, uint64_t *value)
{
    unsigned long long parsed;
    char *suffix;

    if (text[0] == '\0' || text[0] == '-' || text[0] == '+') {
        return -1;
    }
    errno = 0;
    parsed = strtoull(text, &suffix, 0);
    if (errno == ERANGE || suffix == text || *suffix != '\0' ||
        parsed > maximum) {
        return -1;
    }
    *value = (uint64_t)parsed;
    return 0;
}

static int set_key(route_builder_t *builder, const char *key,
                   const char *value, char *error, size_t error_bytes)
{
    cosim_table_route_entry_t *entry = &builder->entry;
    uint64_t parsed;
    unsigned int bit;

    if (strcmp(key, "rc") == 0) {
        bit = ROUTE_KEY_RC;
        if (parse_u64(value, UINT16_MAX, &parsed) != 0) {
            goto invalid_number;
        }
        entry->target.rc_id = cosim_table_cpu_to_le16((uint16_t)parsed);
    } else if (strcmp(key, "device") == 0) {
        bit = ROUTE_KEY_DEVICE;
        if (parse_u64(value, UINT16_MAX, &parsed) != 0) {
            goto invalid_number;
        }
        entry->target.device_instance =
            cosim_table_cpu_to_le16((uint16_t)parsed);
    } else if (strcmp(key, "target") == 0) {
        bit = ROUTE_KEY_TARGET;
        if (strcmp(value, "pf0") != 0) {
            route_error(error, error_bytes,
                        "line %u: target must be pf0", builder->line);
            return -1;
        }
        entry->target.target_type = COSIM_TABLE_TARGET_PF;
        entry->target.pf_index = 0;
    } else if (strcmp(key, "bar") == 0) {
        bit = ROUTE_KEY_BAR;
        if (parse_u64(value, 1, &parsed) != 0) {
            goto invalid_number;
        }
        entry->target.bar_index = (uint8_t)parsed;
    } else if (strcmp(key, "start") == 0) {
        bit = ROUTE_KEY_START;
        if (parse_u64(value, UINT64_MAX, &parsed) != 0) {
            goto invalid_number;
        }
        entry->start_offset = cosim_table_cpu_to_le64(parsed);
    } else if (strcmp(key, "end") == 0) {
        bit = ROUTE_KEY_END;
        if (parse_u64(value, UINT64_MAX, &parsed) != 0) {
            goto invalid_number;
        }
        entry->end_offset = cosim_table_cpu_to_le64(parsed);
    } else if (strcmp(key, "entry_bytes") == 0) {
        bit = ROUTE_KEY_ENTRY_BYTES;
        if (parse_u64(value, UINT32_MAX, &parsed) != 0) {
            goto invalid_number;
        }
        entry->entry_bytes = cosim_table_cpu_to_le32((uint32_t)parsed);
    } else if (strcmp(key, "stride_bytes") == 0) {
        bit = ROUTE_KEY_STRIDE_BYTES;
        if (parse_u64(value, UINT32_MAX, &parsed) != 0) {
            goto invalid_number;
        }
        entry->stride_bytes = cosim_table_cpu_to_le32((uint32_t)parsed);
    } else if (strcmp(key, "index_base") == 0) {
        bit = ROUTE_KEY_INDEX_BASE;
        if (parse_u64(value, UINT32_MAX, &parsed) != 0) {
            goto invalid_number;
        }
        entry->index_base = cosim_table_cpu_to_le32((uint32_t)parsed);
    } else if (strcmp(key, "handler") == 0) {
        size_t bytes = strlen(value);

        bit = ROUTE_KEY_HANDLER;
        if (bytes == 0 || bytes >= sizeof(entry->handler_name)) {
            route_error(error, error_bytes,
                        "line %u: handler must contain 1 to %u bytes",
                        builder->line,
                        (unsigned int)sizeof(entry->handler_name) - 1);
            return -1;
        }
        memcpy(entry->handler_name, value, bytes + 1);
    } else if (strcmp(key, "operations") == 0) {
        bit = ROUTE_KEY_OPERATIONS;
        if (strcmp(value, "write") == 0) {
            entry->operation_mask =
                cosim_table_cpu_to_le32(COSIM_TABLE_OP_WRITE);
        } else if (strcmp(value, "write,read") == 0) {
            entry->operation_mask = cosim_table_cpu_to_le32(
                COSIM_TABLE_OP_WRITE | COSIM_TABLE_OP_READ_DWORD);
        } else {
            route_error(error, error_bytes,
                        "line %u: operations must be write or write,read",
                        builder->line);
            return -1;
        }
    } else {
        route_error(error, error_bytes, "line %u: unknown key '%s'",
                    builder->line, key);
        return -1;
    }

    if ((builder->seen & bit) != 0) {
        route_error(error, error_bytes, "line %u: duplicate key '%s'",
                    builder->line, key);
        return -1;
    }
    builder->seen |= bit;
    return 0;

invalid_number:
    route_error(error, error_bytes, "line %u: invalid numeric value for '%s'",
                builder->line, key);
    return -1;
}

static int append_route(route_builder_t *builder,
                        cosim_table_route_entry_t **entries, size_t *count,
                        size_t *capacity, char *error, size_t error_bytes)
{
    cosim_table_route_entry_t *grown;
    uint64_t start;
    uint64_t end;
    uint64_t span;
    uint64_t last_slot;
    uint64_t last_index;
    uint32_t entry_bytes;
    uint32_t stride_bytes;
    uint32_t index_base;
    size_t new_capacity;

    if ((builder->seen & ROUTE_REQUIRED_KEYS) != ROUTE_REQUIRED_KEYS) {
        route_error(error, error_bytes,
                    "route beginning at line %u is missing a required key",
                    builder->line);
        return -1;
    }
    if ((builder->seen & ROUTE_KEY_OPERATIONS) == 0) {
        builder->entry.operation_mask =
            cosim_table_cpu_to_le32(COSIM_TABLE_OP_WRITE);
    }

    start = cosim_table_le64_to_cpu(builder->entry.start_offset);
    end = cosim_table_le64_to_cpu(builder->entry.end_offset);
    entry_bytes = cosim_table_le32_to_cpu(builder->entry.entry_bytes);
    stride_bytes = cosim_table_le32_to_cpu(builder->entry.stride_bytes);
    index_base = cosim_table_le32_to_cpu(builder->entry.index_base);
    if (start >= end) {
        route_error(error, error_bytes,
                    "route beginning at line %u has an invalid range",
                    builder->line);
        return -1;
    }
    if (entry_bytes == 0 || stride_bytes == 0 || stride_bytes < entry_bytes) {
        route_error(error, error_bytes,
                    "route beginning at line %u has invalid entry geometry",
                    builder->line);
        return -1;
    }
    span = end - start;
    if (span < entry_bytes) {
        route_error(error, error_bytes,
                    "route beginning at line %u is shorter than one entry",
                    builder->line);
        return -1;
    }
    last_slot = (span - entry_bytes) / stride_bytes;
    last_index = (uint64_t)index_base + last_slot;
    if (last_index > UINT32_MAX) {
        route_error(error, error_bytes,
                    "route beginning at line %u overflows the entry index",
                    builder->line);
        return -1;
    }
    if (*count >= (size_t)UINT32_MAX) {
        route_error(error, error_bytes, "too many routes");
        return -1;
    }
    builder->entry.route_id = cosim_table_cpu_to_le32((uint32_t)*count);

    if (*count == *capacity) {
        if (*capacity == 0) {
            new_capacity = 8;
        } else if (*capacity > SIZE_MAX / 2) {
            route_error(error, error_bytes, "too many routes");
            return -1;
        } else {
            new_capacity = *capacity * 2;
        }
        if (new_capacity > SIZE_MAX / sizeof(**entries)) {
            route_error(error, error_bytes, "too many routes");
            return -1;
        }
        grown = realloc(*entries, new_capacity * sizeof(**entries));
        if (grown == NULL) {
            route_error(error, error_bytes, "out of memory while loading routes");
            return -1;
        }
        *entries = grown;
        *capacity = new_capacity;
    }
    (*entries)[*count] = builder->entry;
    ++*count;
    return 0;
}

static int compare_u64(uint64_t left, uint64_t right)
{
    return left < right ? -1 : left > right ? 1 : 0;
}

static int compare_routes(const void *left_pointer, const void *right_pointer)
{
    const cosim_table_route_entry_t *left = left_pointer;
    const cosim_table_route_entry_t *right = right_pointer;
    int result;

    result = compare_u64(cosim_table_le16_to_cpu(left->target.rc_id),
                         cosim_table_le16_to_cpu(right->target.rc_id));
    if (result == 0) {
        result = compare_u64(
            cosim_table_le16_to_cpu(left->target.device_instance),
            cosim_table_le16_to_cpu(right->target.device_instance));
    }
    if (result == 0) {
        result = compare_u64(left->target.target_type,
                             right->target.target_type);
    }
    if (result == 0) {
        result = compare_u64(left->target.pf_index, right->target.pf_index);
    }
    if (result == 0) {
        result = compare_u64(left->target.bar_index,
                             right->target.bar_index);
    }
    if (result == 0) {
        result = compare_u64(cosim_table_le64_to_cpu(left->start_offset),
                             cosim_table_le64_to_cpu(right->start_offset));
    }
    return result;
}

static int same_route_owner(const cosim_table_route_entry_t *left,
                            const cosim_table_route_entry_t *right)
{
    return cosim_table_le16_to_cpu(left->target.rc_id) ==
               cosim_table_le16_to_cpu(right->target.rc_id) &&
           cosim_table_le16_to_cpu(left->target.device_instance) ==
               cosim_table_le16_to_cpu(right->target.device_instance) &&
           left->target.target_type == right->target.target_type &&
           left->target.pf_index == right->target.pf_index &&
           left->target.bar_index == right->target.bar_index;
}

static int validate_overlap(const cosim_table_route_entry_t *entries,
                            size_t count, char *error, size_t error_bytes)
{
    cosim_table_route_entry_t *ordered;
    size_t i;

    if (count < 2) {
        return 0;
    }
    if (count > SIZE_MAX / sizeof(*ordered)) {
        route_error(error, error_bytes, "too many routes");
        return -1;
    }
    ordered = malloc(count * sizeof(*ordered));
    if (ordered == NULL) {
        route_error(error, error_bytes,
                    "out of memory while validating routes");
        return -1;
    }
    memcpy(ordered, entries, count * sizeof(*ordered));
    qsort(ordered, count, sizeof(*ordered), compare_routes);
    for (i = 1; i < count; ++i) {
        if (same_route_owner(&ordered[i - 1], &ordered[i]) &&
            cosim_table_le64_to_cpu(ordered[i].start_offset) <
                cosim_table_le64_to_cpu(ordered[i - 1].end_offset)) {
            route_error(error, error_bytes,
                        "route %u overlaps route %u",
                        cosim_table_le32_to_cpu(ordered[i].route_id),
                        cosim_table_le32_to_cpu(ordered[i - 1].route_id));
            free(ordered);
            return -1;
        }
    }
    free(ordered);
    return 0;
}

static uint64_t generation_hash(const void *data, size_t bytes)
{
    const uint8_t *octets = data;
    uint64_t hash = UINT64_C(14695981039346656037);
    size_t i;

    for (i = 0; i < bytes; ++i) {
        hash ^= octets[i];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

int cosim_table_route_load(const char *path, cosim_table_route_map_t *map,
                           char *error, size_t error_bytes)
{
    cosim_table_route_entry_t *entries = NULL;
    route_builder_t builder;
    size_t count = 0;
    size_t capacity = 0;
    char *line = NULL;
    size_t line_capacity = 0;
    unsigned int line_number = 0;
    int in_section = 0;
    int result = -1;
    FILE *file;

    if (error != NULL && error_bytes != 0) {
        error[0] = '\0';
    }
    if (path == NULL || map == NULL) {
        route_error(error, error_bytes, "path and map are required");
        return -1;
    }
    file = fopen(path, "r");
    if (file == NULL) {
        route_error(error, error_bytes, "cannot open '%s': %s", path,
                    strerror(errno));
        return -1;
    }
    memset(&builder, 0, sizeof(builder));

    while (getline(&line, &line_capacity, file) >= 0) {
        char *text;
        char *equals;
        size_t text_bytes;

        ++line_number;
        text = trim(line);
        if (text[0] == '\0' || text[0] == '#' || text[0] == ';') {
            continue;
        }
        text_bytes = strlen(text);
        if (text[0] == '[') {
            if (text_bytes < 9 || text[text_bytes - 1] != ']' ||
                strncmp(text, "[route.", 7) != 0) {
                route_error(error, error_bytes,
                            "line %u: invalid route section", line_number);
                goto done;
            }
            text[text_bytes - 1] = '\0';
            if (text[7] == '\0') {
                route_error(error, error_bytes,
                            "line %u: route name is empty", line_number);
                goto done;
            }
            if (in_section &&
                append_route(&builder, &entries, &count, &capacity, error,
                             error_bytes) != 0) {
                goto done;
            }
            memset(&builder, 0, sizeof(builder));
            builder.line = line_number;
            in_section = 1;
            continue;
        }
        if (!in_section) {
            route_error(error, error_bytes,
                        "line %u: key appears outside a route section",
                        line_number);
            goto done;
        }
        equals = strchr(text, '=');
        if (equals == NULL) {
            route_error(error, error_bytes, "line %u: expected key=value",
                        line_number);
            goto done;
        }
        *equals = '\0';
        builder.line = line_number;
        if (set_key(&builder, trim(text), trim(equals + 1), error,
                    error_bytes) != 0) {
            goto done;
        }
    }
    if (ferror(file)) {
        route_error(error, error_bytes, "error reading '%s'", path);
        goto done;
    }
    if (!in_section) {
        route_error(error, error_bytes, "route file contains no routes");
        goto done;
    }
    if (append_route(&builder, &entries, &count, &capacity, error,
                     error_bytes) != 0 ||
        validate_overlap(entries, count, error, error_bytes) != 0) {
        goto done;
    }

    free(map->entries);
    map->entries = entries;
    map->count = count;
    map->generation_hash =
        generation_hash(entries, count * sizeof(entries[0]));
    entries = NULL;
    result = 0;

done:
    free(entries);
    free(line);
    fclose(file);
    return result;
}

void cosim_table_route_free(cosim_table_route_map_t *map)
{
    if (map == NULL) {
        return;
    }
    free(map->entries);
    map->entries = NULL;
    map->count = 0;
    map->generation_hash = 0;
}

const cosim_table_route_entry_t *cosim_table_route_match(
    const cosim_table_route_map_t *map, const cosim_table_target_t *target,
    uint64_t bar_offset, uint8_t operation)
{
    size_t i;

    if (map == NULL || target == NULL ||
        (operation != COSIM_TABLE_OP_WRITE &&
         operation != COSIM_TABLE_OP_READ_DWORD)) {
        return NULL;
    }
    for (i = 0; i < map->count; ++i) {
        const cosim_table_route_entry_t *route = &map->entries[i];
        uint64_t start;
        uint64_t end;
        uint64_t displacement;
        uint64_t entry_start;
        uint64_t within_entry;
        uint32_t entry_bytes;
        uint32_t stride_bytes;

        if (cosim_table_le16_to_cpu(route->target.rc_id) !=
                cosim_table_le16_to_cpu(target->rc_id) ||
            cosim_table_le16_to_cpu(route->target.device_instance) !=
                cosim_table_le16_to_cpu(target->device_instance) ||
            route->target.target_type != target->target_type ||
            route->target.pf_index != target->pf_index ||
            route->target.bar_index != target->bar_index ||
            (cosim_table_le32_to_cpu(route->operation_mask) & operation) == 0) {
            continue;
        }
        start = cosim_table_le64_to_cpu(route->start_offset);
        end = cosim_table_le64_to_cpu(route->end_offset);
        entry_bytes = cosim_table_le32_to_cpu(route->entry_bytes);
        stride_bytes = cosim_table_le32_to_cpu(route->stride_bytes);
        if (start >= end || entry_bytes == 0 ||
            stride_bytes < entry_bytes || end - start < entry_bytes ||
            bar_offset < start || bar_offset >= end) {
            continue;
        }
        displacement = bar_offset - start;
        within_entry = displacement % stride_bytes;
        if (within_entry >= entry_bytes) {
            continue;
        }
        entry_start = bar_offset - within_entry;
        if (entry_start > end - entry_bytes) {
            continue;
        }
        if (operation == COSIM_TABLE_OP_READ_DWORD &&
            ((bar_offset & UINT64_C(3)) != 0 || entry_bytes < 4 ||
             within_entry > entry_bytes - 4 || bar_offset > end - 4)) {
            continue;
        }
        return route;
    }
    return NULL;
}

int cosim_table_route_slice(const cosim_table_route_entry_t *route,
                            uint64_t bar_offset, uint32_t payload_bytes,
                            uint64_t *first_index, uint32_t *entry_count)
{
    uint64_t start;
    uint64_t end;
    uint64_t displacement;
    uint64_t count;
    uint64_t first;
    uint64_t last_displacement;
    uint64_t last_start;
    uint32_t entry_bytes;
    uint32_t stride_bytes;
    uint32_t index_base;

    if (route == NULL || first_index == NULL || entry_count == NULL) {
        return -1;
    }
    start = cosim_table_le64_to_cpu(route->start_offset);
    end = cosim_table_le64_to_cpu(route->end_offset);
    entry_bytes = cosim_table_le32_to_cpu(route->entry_bytes);
    stride_bytes = cosim_table_le32_to_cpu(route->stride_bytes);
    index_base = cosim_table_le32_to_cpu(route->index_base);
    if (start >= end || entry_bytes == 0 || stride_bytes < entry_bytes ||
        payload_bytes == 0 || payload_bytes % entry_bytes != 0 ||
        bar_offset < start || bar_offset >= end) {
        return -1;
    }
    displacement = bar_offset - start;
    if (displacement % stride_bytes != 0) {
        return -1;
    }
    count = payload_bytes / entry_bytes;
    first = (uint64_t)index_base + displacement / stride_bytes;
    if (first > UINT32_MAX || count - 1 > UINT32_MAX - first ||
        count - 1 > (UINT64_MAX - bar_offset) / stride_bytes) {
        return -1;
    }
    last_displacement = (count - 1) * stride_bytes;
    last_start = bar_offset + last_displacement;
    if (end - start < entry_bytes || last_start > end - entry_bytes) {
        return -1;
    }
    *first_index = first;
    *entry_count = (uint32_t)count;
    return 0;
}
