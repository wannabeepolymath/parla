#pragma once
// Pure prompt policy for bridge.cpp. No JNI or whisper includes, so it can be checked on the host.
#include <algorithm>
#include <string>
#include <vector>

namespace parla {
// Kotlin sends byte-admitted terms joined with "\n"; terms are whitespace-normalized, so never contain one.
inline std::vector<std::string> split_lines(const std::string& s) {
    std::vector<std::string> out;
    size_t start = 0;
    while (start <= s.size()) {
        const auto end = std::min(s.find('\n', start), s.size());
        if (end > start) out.push_back(s.substr(start, end - start));
        start = end + 1;
    }
    return out;
}

inline std::string join(const std::vector<std::string>& terms) {
    std::string out;
    for (const auto& t : terms) { if (!out.empty()) out += ", "; out += t; }
    return out;
}

// Languages of a loaded multilingual model: the language tokens sit between sot and translate.
inline int language_count(int sot, int translate) { return std::max(0, translate - sot - 1); }

// terms: priority order. count: tokens for a UTF-8 string. Returns the ", "-joined prompt.
template <class Count>
std::string select_prompt(const std::vector<std::string>& terms, int capacity, Count count) {
    std::vector<std::string> selected;
    long used = 0;
    for (const auto& term : terms) {
        const long cost = count(selected.empty() ? term : ", " + term);
        if (used + cost <= capacity) { selected.push_back(term); used += cost; }
    }
    // Tokenization is not additive across boundaries; the joined prompt is what whisper sees.
    while (!selected.empty() && count(join(selected)) > capacity) selected.pop_back();
    return join(selected);
}
}
