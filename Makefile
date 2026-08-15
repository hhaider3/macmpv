.PHONY: build run app dmg clean

build:
	swift build || swift build --disable-sandbox

run:
	swift run macmpv || swift run --disable-sandbox macmpv

app:
	zsh Scripts/build-app.sh release

dmg:
	zsh Scripts/package-dmg.sh

clean:
	swift package clean
