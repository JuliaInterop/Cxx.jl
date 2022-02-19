const JLL_ENV_CLANG_TARGETS_MAPPING = Dict(
    "aarch64-apple-darwin20"=>"aarch64-apple-darwin20",
    "aarch64-linux-gnu"=>"aarch64-unknown-linux-gnu",
    "aarch64-linux-musl"=>"aarch64-unknown-linux-musl",
    "armv7l-linux-gnueabihf"=>"armv7l-unknown-linux-gnueabihf",
    "armv7l-linux-musleabihf"=>"armv7l-unknown-linux-musleabihf",
    "i686-linux-gnu"=>"i686-unknown-linux-gnu",
    "i686-linux-musl"=>"i686-unknown-linux-musl",
    "i686-w64-mingw32"=>"i686-w64-windows-gnu",
    "powerpc64le-linux-gnu"=>"powerpc64le-unknown-linux-gnu",
    "x86_64-apple-darwin14"=>"x86_64-apple-darwin14",
    "x86_64-linux-gnu"=>"x86_64-unknown-linux-gnu",
    "x86_64-linux-musl"=>"x86_64-unknown-linux-musl",
    "x86_64-unknown-freebsd11.1"=>"x86_64-unknown-freebsd11.1",
    "x86_64-w64-mingw32"=>"x86_64-w64-windows-gnu",
)

target(triple::String) = get(JLL_ENV_CLANG_TARGETS_MAPPING, triple, "unknown")
target(p::Platform) = target(__triplet(p))
