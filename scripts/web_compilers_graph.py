"""Read pinned native graph evidence for the published compiler regression."""
from pathlib import Path


class Reader:
    def __init__(self, path):
        self.data = Path(path).read_bytes()
        assert self.data[:5] == b'BRAG\x03'
        assert int.from_bytes(self.data[5:9], 'big') == len(self.data) - 9
        self.offset = 9

    def take(self, n):
        end = self.offset + n
        assert end <= len(self.data)
        value = self.data[self.offset:end]
        self.offset = end
        return value

    def u32(self):
        return int.from_bytes(self.take(4), 'big')

    def string(self):
        return self.take(self.u32()).decode()

    def strings(self):
        return [self.string() for _ in range(self.u32())]

    def mapping(self, value):
        result = {}
        for _ in range(self.u32()):
            key = self.string()
            result[key] = value()
        return result


def native_graph(root):
    r = Reader(root / '.dart_tool/build_runner_accelerator/graph-v3.bin')
    assert r.u32() == 7, 'update the pinned native graph reader'
    r.string()
    r.take(1)
    for _ in range(r.u32()):
        r.string(); r.take(1); r.string(); r.take(8)
    actions = {}
    for _ in range(r.u32()):
        key = r.string()
        has_part = r.take(1)
        assert has_part in (b'\x00', b'\x01')
        if has_part == b'\x01':
            r.string(); r.string(); r.string()
        builder, primary = r.string(), r.string()
        reads, resolver_reads, entrypoints = r.strings(), r.strings(), r.strings()
        globs = [(r.string(), r.string()) for _ in range(r.u32())]
        outputs = r.strings()
        r.mapping(r.string)
        status = r.string()
        actions[key] = dict(builder=builder, input=primary, reads=reads,
                            resolver_reads=resolver_reads, entrypoints=entrypoints,
                            globs=globs, outputs=outputs, status=status)
    r.mapping(r.strings)
    r.mapping(lambda: r.take(1))
    inputs = r.mapping(r.strings)
    globs = r.mapping(lambda: r.mapping(r.strings))
    r.strings()
    r.take(1)
    assert r.offset == len(r.data)
    return actions, inputs, globs
