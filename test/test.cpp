#include <iostream>
#include <stdint.h>

struct foo {
  int x;
};

uint64_t foo2() { return 1; }

class PrintTest {
public:
  PrintTest() { abc = 1; };
  int64_t abc;
};

namespace foo13 {
class bar {
public:
  enum baz { A, B, C };
};
} // namespace foo13