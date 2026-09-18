.PHONY: run build deploy

run:
	cd rust && cargo ndk -t arm64-v8a -t x86_64 -o ../flutter/android/app/src/main/jniLibs build --release -p filedrop-ffi && cd ../flutter && flutter run -d android

build:
	cd rust && cargo ndk -t arm64-v8a -t x86_64 -o ../flutter/android/app/src/main/jniLibs build --release -p filedrop-ffi && cd ../flutter && flutter build apk

deploy: build
	git checkout main
	git add -A
	git commit -m "$$(copilot -sp 'Analyze the staged git changes and generate a concise commit message. Output ONLY the commit message. Do not execute any commands. Do not include quotes, markdown, explanation, or bullet points.')"
	git push origin main
