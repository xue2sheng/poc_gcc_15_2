# gcc 15.2 for several targets

Although there are different targets, the last stage is **Ubuntu 24.04**

# MUSL

Do not forget to statically compile once your g++ points to */opt/toolchain/gcc15-musl/bin/g++*

**main.cpp**

    #include <print>
    int main() {
            std::println("Hello World!");
            return 0;
    }

**Makefile**

    all: main.cpp
        g++ -std=c++23 -static -o test001 main.cpp
    clean: test001
        rm -rf test001

Regarding **TBB**

**main.cpp**

    #include <tbb/parallel_for.h>
    #include <tbb/parallel_sort.h> // Moved to global scope
    #include <tbb/global_control.h>
    #include <vector>
    #include <algorithm>
    #include <print>
    #include <numeric>
    int main() {
        const int size = 10'000'000;
        std::vector<int> data(size);
        // Initialize data in parallel
        tbb::parallel_for(tbb::blocked_range<size_t>(0, size), [&](const tbb::blocked_range<size_t>& r) {
            for (size_t i = r.begin(); i != r.end(); ++i) {
                data[i] = static_cast<int>(size - i);
            }
        });
        std::println("Data initialized. Sorting {} elements...", size);
        // Now this will work perfectly
        tbb::parallel_sort(data.begin(), data.end());
        std::println("First 5 elements: {}, {}, {}, {}, {}", data[0], data[1], data[2], data[3], data[4]);
        return 0;
    }

**Makefile**

    CXX      = g++
    CXXFLAGS = -std=c++23 -O3 -Wall -Wextra
    LDFLAGS  = -static-libstdc++ -static-libgcc
    # TBB Paths (Adjust if you installed to a custom directory)
    TBB_DIR  = /opt/toolchain/gcc15-musl/tbb
    INCLUDES = -I$(TBB_DIR)/include
    LIBS     = $(TBB_DIR)/lib/libtbb.a
    # Musl requires pthread and math libraries for TBB
    LDLIBS   = -lpthread -lm
    # Target
    TARGET   = tbb_example
    SRC      = main.cpp
    all: $(TARGET)
    $(TARGET): $(SRC)
            $(CXX) $(CXXFLAGS) $(INCLUDES) $(SRC) -o $(TARGET) $(LIBS) $(LDFLAGS) $(LDLIBS)
    clean:
            rm -f $(TARGET)
    .PHONY: all clean

