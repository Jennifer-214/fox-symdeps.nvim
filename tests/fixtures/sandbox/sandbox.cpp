#include <cstdint>
#include <cstring>

// ─── Toy 16-byte money type. Nothing real — mangle it freely. ───
// TRY: change `__int128 v;` to `int64_t v;` and watch the panel: 16 B → 8 B, 4/line → 8/line.
struct Money {
    __int128 v;  // 16 B value
};

// ─── A struct whose field straddles a 64-byte cache line (a hot-path smell). ───
struct Packet {
    char header[40];   // bytes 0..39   (line 0)
    char payload[64];  // bytes 40..103 → STRADDLES line 0/1
    int  length;       // bytes 104..107 (line 1)
};

// ─── Embedder: contains Money as a field (the "Embedded in" consumers). ───
struct Position {
    Money entry_price;
    Money exit_price;
    int   qty;
};

// ─── Operations on Money (the "Used as input" / "Returned by" consumers). ───
static Money money_add(Money a, Money b) { Money r; r.v = a.v + b.v; return r; }  // input x2, returned
static Money money_zero()                { Money m; m.v = 0; return m; }          // returned
static void  money_accumulate(Money* acc, Money x) { acc->v += x.v; }             // input
static bool  money_eq(const Money& a, const Money& b) {                           // input x2, byte
    return std::memcmp(&a, &b, sizeof(Money)) == 0;
}

static void demo() {
    Money a = money_zero();        // instantiated
    Money b;                        // instantiated
    b.v = 100;
    Money c = money_add(a, b);     // input (call args)
    money_accumulate(&c, b);        // input
    Position p;
    p.entry_price = c;
    char buf[sizeof(Money)];        // byte: sizeof
    (void)p;
    (void)buf;
    (void)money_eq(a, b);
}

int main() { demo(); return 0; }
