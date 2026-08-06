.PHONY: build run app clean

build:
	swift build || swift build --disable-sandbox

run:
	swift run macmpv || swift run --disable-sandbox macmpv

app:
	zsh Scripts/build-app.sh release

clean:
	swift package clean
