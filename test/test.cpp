#include <iostream>
#include <stdint.h>
#include <vector>

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

template <typename T> // primary template
struct is_void : std::false_type {};

template <> // explicit specialization for T = void
struct is_void<void> : std::true_type {};