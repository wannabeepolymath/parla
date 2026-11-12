#!/usr/bin/env python3
"""Reproduce vendored source without models. Python standard library only."""
import hashlib, io, pathlib, tarfile, urllib.request
revision = 'f049fff95a089aa9969deb009cdd4892b3e74916'
sha256 = '279af4ce60dbf397362868f3bacc75b56a4332ac2541cae155070093f6aaf0e3'
root = pathlib.Path(__file__).resolve().parent
archive = root / 'whisper-v1.9.1.tar.gz'
if not archive.exists():
    with urllib.request.urlopen('https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/' + revision) as response:
        archive.write_bytes(response.read())
assert hashlib.sha256(archive.read_bytes()).hexdigest() == sha256
allowed = {'CMakeLists.txt', 'LICENSE', 'cmake', 'include', 'src', 'ggml'}
with tarfile.open(fileobj=io.BytesIO(archive.read_bytes())) as tar:
    for entry in tar:
        parts = pathlib.PurePosixPath(entry.name).parts[1:]
        if not parts or parts[0] not in allowed or '..' in parts or entry.issym() or entry.islnk(): continue
        # Keep upstream ggml source, CMake modules and notices, omit its unrelated examples/tests.
        if parts[0] == 'ggml' and len(parts) > 1 and parts[1] not in {'CMakeLists.txt','LICENSE','cmake','include','src'}: continue
        if len(parts) > 2 and parts[0] == 'ggml' and parts[1] == 'src' and parts[2] in {'ggml-hip', 'ggml-cann', 'ggml-vulkan', 'ggml-musa', 'ggml-zendnn', 'ggml-virtgpu', 'ggml-sycl', 'ggml-opencl', 'ggml-hexagon', 'ggml-openvino', 'ggml-metal', 'ggml-rpc', 'ggml-zdnn', 'ggml-webgpu', 'ggml-cuda', 'ggml-blas'}: continue
        dest = root / 'vendor' / 'whisper' / pathlib.Path(*parts)
        if entry.isdir(): dest.mkdir(parents=True, exist_ok=True)
        elif entry.isfile():
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(tar.extractfile(entry).read())
print('Verified whisper.cpp v1.9.1', revision, sha256)
