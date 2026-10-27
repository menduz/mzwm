# A layer surface on the overlay layer, as the notifications of dunst: a red
# band below the bar, over all the width of the output. It has no input
# region, thus the pointer goes through it to the bar and to the tooltip.
#
# Usage: test-layer.py <mapped file> <top> <height>
#
# The helper writes <mapped file> after the first commit with a buffer, and
# stops at SIGTERM. The protocol modules come from tests.nix
# (kwm_test_protocols).
import mmap
import os
import sys

from pywayland.client import Display

from kwm_test_protocols.wayland import WlCompositor, WlShm
from kwm_test_protocols.wlr_layer_shell_unstable_v1 import ZwlrLayerShellV1, ZwlrLayerSurfaceV1

mapped_file = sys.argv[1]
top, height = int(sys.argv[2]), int(sys.argv[3])

display = Display()
display.connect()

globals_ = {}


def on_global(registry, id_, interface, version):
    if interface == "wl_compositor":
        globals_["compositor"] = registry.bind(id_, WlCompositor, 4)
    elif interface == "wl_shm":
        globals_["shm"] = registry.bind(id_, WlShm, 1)
    elif interface == "zwlr_layer_shell_v1":
        globals_["layer_shell"] = registry.bind(id_, ZwlrLayerShellV1, 1)


registry = display.get_registry()
registry.dispatcher["global"] = on_global
display.roundtrip()

compositor = globals_["compositor"]
surface = compositor.create_surface()
region = compositor.create_region()
surface.set_input_region(region)
region.destroy()

layer_surface = globals_["layer_shell"].get_layer_surface(
    surface, None, ZwlrLayerShellV1.layer.overlay.value, "kwm-test"
)
anchor = ZwlrLayerSurfaceV1.anchor
layer_surface.set_anchor(anchor.top.value | anchor.left.value | anchor.right.value)
layer_surface.set_size(0, height)
layer_surface.set_margin(top, 0, 0, 0)
layer_surface.set_exclusive_zone(-1)
buffers = []


def on_configure(layer_surface, serial, width, height):
    layer_surface.ack_configure(serial)
    if buffers:
        return
    stride = width * 4
    size = stride * height
    fd = os.memfd_create("kwm-test-layer")
    os.ftruncate(fd, size)
    data = mmap.mmap(fd, size)
    # #ff0000: no color of the bar or of the tooltip.
    data.write(b"\x00\x00\xff\xff" * (width * height))
    pool = globals_["shm"].create_pool(fd, size)
    buffer = pool.create_buffer(0, width, height, stride, WlShm.format.argb8888.value)
    pool.destroy()
    os.close(fd)
    buffers.append((buffer, data))
    surface.attach(buffer, 0, 0)
    surface.damage_buffer(0, 0, width, height)
    surface.commit()


layer_surface.dispatcher["configure"] = on_configure
surface.commit()

display.roundtrip()
# The roundtrip after the commit with the buffer: river has the buffer.
display.roundtrip()
open(mapped_file, "w").close()

while display.dispatch(block=True) != -1:
    pass
