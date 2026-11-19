// Host self-check for bridge_policy.h:
// c++ -std=c++17 -Wall -Wextra -o "$TMPDIR/bridge_policy_test" android/native/bridge_policy_test.cpp && "$TMPDIR/bridge_policy_test"
#undef NDEBUG
#include "bridge_policy.h"
#include <algorithm>
#include <cassert>
#include <cctype>
#include <cstdio>
#include <set>
#include <sstream>

namespace {
long bytes(const std::string& s) { return long(s.size()); }

// Test-only mirror of Kotlin VocabularyHints.select admission (ASCII case folding is enough here).
std::vector<std::string> admit(const std::vector<std::string>& words) {
    std::vector<std::string> out; std::set<std::string> seen;
    for (const auto& raw : words) {
        std::istringstream in(raw); std::string part, word;
        while (in >> part) word += (word.empty() ? "" : " ") + part;
        std::string key = word;
        std::transform(key.begin(), key.end(), key.begin(), [](unsigned char c) { return char(std::tolower(c)); });
        if (!word.empty() && word.size() <= 256 && seen.insert(key).second) out.push_back(word);
    }
    return out;
}

size_t separators(const std::string& s) {
    size_t n = 0;
    for (size_t i = s.find(", "); i != std::string::npos; i = s.find(", ", i + 2)) ++n;
    return n;
}
}

int main() {
    // Mirrors fixtures/desktop-android-v1.json "promptBudget" verbatim (count = UTF-8 byte length).
    struct Case { std::vector<std::string> words; int capacity; std::vector<std::string> expected; };
    const std::vector<Case> cases = {
        {{"alpha", "beta", "gamma"}, 11, {"alpha", "beta"}},
        {{"alpha", "a-very-long-term", "b"}, 8, {"alpha", "b"}},
        {{"Café", "次", "नमस्ते"}, 10, {"Café", "次"}},
        {{"  Name0 ", "name0", "Name1"}, 100, {"Name0", "Name1"}},
        {{"alpha"}, 0, {}},
    };
    for (const auto& c : cases) {
        std::string wire;  // Kotlin wire format: admitted terms joined with "\n"
        for (const auto& t : admit(c.words)) wire += (wire.empty() ? "" : "\n") + t;
        assert(parla::select_prompt(parla::split_lines(wire), c.capacity, bytes) == parla::join(c.expected));
    }

    // Non-additive counters: the joined prompt never exceeds capacity.
    const auto onePerSeparator = [](const std::string& s) { return bytes(s) + long(separators(s)); };
    const auto superadditive = [](const std::string& s) { const long n = long(separators(s)); return bytes(s) + n * n; };
    const std::vector<std::string> terms = {"alpha", "b", "gamma", "de", "x", "longer-term", "y"};
    for (int capacity = 0; capacity <= 60; ++capacity) {
        assert(onePerSeparator(parla::select_prompt(terms, capacity, onePerSeparator)) <= capacity);
        assert(superadditive(parla::select_prompt(terms, capacity, superadditive)) <= capacity);
    }

    assert(parla::split_lines("").empty());
    assert((parla::split_lines("a\n\nb\n") == std::vector<std::string>{"a", "b"}));
    std::puts("bridge_policy_test: PASS");
}
