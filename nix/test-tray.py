"""Tray items for the tests of kwm.

Usage: test-tray.py <command fifo> <id>:<icon name>:<status>...

Waits for the StatusNotifierWatcher of kwm, then registers one item for each
argument, in that order. Then it reads one command per line from the fifo:

    status ID STATUS   give the item ID the status STATUS (Active, Passive
                       or NeedsAttention), with the NewStatus signal
    remove ID          close the connection of the item ID: the watcher
                       forgets it
    add ID:ICON:STATUS register one more item
"""

import asyncio
import sys

from dbus_next import Message, PropertyAccess
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, dbus_property, signal

WATCHER = "org.kde.StatusNotifierWatcher"


class Item(ServiceInterface):
    def __init__(self, id_, icon, status):
        super().__init__("org.kde.StatusNotifierItem")
        self.id = id_
        self.icon = icon
        self.status = status

    @dbus_property(access=PropertyAccess.READ)
    def Id(self) -> "s":
        return self.id

    @dbus_property(access=PropertyAccess.READ)
    def Status(self) -> "s":
        return self.status

    @dbus_property(access=PropertyAccess.READ)
    def IconName(self) -> "s":
        return self.icon

    @signal()
    def NewStatus(self) -> "s":
        return self.status


async def call(bus, destination, path, interface, member, signature, body):
    return await bus.call(
        Message(
            destination=destination,
            path=path,
            interface=interface,
            member=member,
            signature=signature,
            body=body,
        )
    )


async def main():
    fifo, specs = sys.argv[1], sys.argv[2:]
    bus = await MessageBus().connect()
    while not (
        await call(
            bus,
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameHasOwner",
            "s",
            [WATCHER],
        )
    ).body[0]:
        await asyncio.sleep(0.1)

    # One connection for each item. The watcher keeps the order of the
    # registrations.
    items = {}

    async def add(spec):
        id_, icon, status = spec.split(":")
        item_bus = await MessageBus().connect()
        item = Item(id_, icon, status)
        item_bus.export("/StatusNotifierItem", item)
        await call(
            item_bus,
            WATCHER,
            "/StatusNotifierWatcher",
            WATCHER,
            "RegisterStatusNotifierItem",
            "s",
            [item_bus.unique_name],
        )
        items[id_] = (item_bus, item)

    for spec in specs:
        await add(spec)

    loop = asyncio.get_running_loop()
    with open(fifo) as commands:
        while True:
            line = await loop.run_in_executor(None, commands.readline)
            if not line:
                break
            words = line.split()
            if words[0] == "status":
                _, item = items[words[1]]
                item.status = words[2]
                item.NewStatus()
            elif words[0] == "remove":
                item_bus, _ = items.pop(words[1])
                item_bus.disconnect()
            elif words[0] == "add":
                await add(words[1])
    await asyncio.Event().wait()


asyncio.run(main())
