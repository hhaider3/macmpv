.PHONY: build run app dmg dmg-torrents clean

build:
	swift build || swift build --disable-sandbox

run:
	swift run macmpv || swift run --disable-sandbox macmpv

app:
	zsh Scripts/build-app.sh release

dmg:
	zsh Scripts/package-dmg.sh

dmg-torrents:
	zsh Scripts/package-dmg.sh torrents

clean:
	swift package clean
