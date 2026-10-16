#pragma once
#include <functional>
#include <utility>

// Signing is synchronous on its worker thread. Nested scopes map actual file /
// page work into the parent operation; thread-local state isolates concurrent jobs.
namespace ZSigningProgress {
inline thread_local std::function<void(double)> callback;
inline void Report(double fraction) {
    if (callback) callback(fraction);
}
class Scope {
    std::function<void(double)> previous;
public:
    explicit Scope(std::function<void(double)> next) : previous(std::move(callback)) {
        callback = std::move(next);
    }
    Scope(double start, double end) : previous(std::move(callback)) {
        if (previous) {
            callback = [parent = previous, start, end](double fraction) {
                parent(start + (end - start) * fraction);
            };
        }
    }
    ~Scope() { callback = std::move(previous); }
    Scope(const Scope&) = delete;
    Scope& operator=(const Scope&) = delete;
};
}
