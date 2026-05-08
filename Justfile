test:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "=== Flutter tests ==="
    flutter test test/

    echo "=== Android tests ==="
    (cd android && ./gradlew testDebugUnitTest)

    echo "=== iOS tests ==="
    DEST=$(xcrun simctl list devices available --json \
        | grep -o '"udid" : "[^"]*"' | head -1 \
        | grep -o '"[^"]*"$' | tr -d '"')
    xcodebuild test \
        -workspace example/ios/Runner.xcworkspace \
        -scheme Runner \
        -destination "platform=iOS Simulator,id=$DEST" \
        -only-testing RunnerTests \
        CODE_SIGNING_ALLOWED=NO
