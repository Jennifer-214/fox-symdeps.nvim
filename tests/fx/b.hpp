// b.hpp
#pragma once

struct Foo {
    int x;
};

class Bar {
    int y;
};

template <int N>
struct Baz {
    int z;
};

struct alignas(64) Qux {
    long long a[8];
};
