.PHONY: build run app clean

build:
	swift build

run:
	swift run macmpv

app:
	zsh Scripts/build-app.sh release

clean:
	swift package clean
