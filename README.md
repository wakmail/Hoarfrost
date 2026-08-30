<div align="center">
    <img src="Resources/Icon.svg" width=200 height=200>
    <h1>Hoarfrost</h1>
    <p>The menu bar manager for Macs that cannot run the newest macOS. Click the empty menu bar to walk through your hidden sections, one click at a time.</p>
</div>

![Platform](https://img.shields.io/badge/platform-macOS-blue?style=flat-square)
![Requirements](https://img.shields.io/badge/requirements-macOS%2014%2B-fa4e49?style=flat-square)
[![License](https://img.shields.io/badge/license-GPLv3-green?style=flat-square)](LICENSE)

> [!NOTE]
> Hoarfrost is a fork of [Thaw](https://github.com/thaw-app/Thaw) by Toni Förster, which is itself a fork of [Ice](https://github.com/jordanbaird/Ice) by Jordan Baird. Nearly everything here was built by them. Hoarfrost exists to try a different idea on top of that foundation, for people who like customization or with a lot of menu bar apps. Both projects are excellent, and I use them every single day.

## The idea

Hoarfrost is first and foremost for macOS 14 and 15, where Thaw 2 does not run and Ice is unmaintained. On macOS 26, Thaw remains the better choice.

Ice and Thaw give you one hidden section: click the divider and everything you tucked away comes back. That works until you have thirty menu bar icons and the hidden section is as cluttered as the menu bar was. Hoarfrost's answer is sections plus the click cycle: click empty menu bar space to open your first section, click again for the next, and again to put everything away. No chevrons or icons needed in the bar at all.

Hoarfrost lets you make as many groups as you want. Each group gets its own name, its own icon in the menu bar, its own hotkey, and its own way of showing up:

- **Push**: the classic Ice style horizontal expand
- **Bar**: a floating panel under the menu bar, like the Ice Bar
- **Menu**: a real dropdown, a menu bar app for your menu bar apps

Use one control icon with every group inside it, or one icon per group, or mix. The goal is that you can organize your menu bar the way you organize folders, and make it feel quick while doing it.

## Status

Working, early. The core is in: any number of sections, per section reveal styles including the dropdown, the combined single icon mode, click cycling on empty menu bar space, a right click menu of every section, faster click delivery, and settings import from Thaw and Ice. Tested by hand on macOS 15. No packaged release yet; build it yourself for now. See [TODO.md](TODO.md) for what is next.

Why Thaw 1.3 and not 2.0: Thaw 2.0 requires macOS 26. Hoarfrost keeps macOS 14 and 15 working alongside 26, so it starts from the last release that supported them and pulls forward what it can from 2.0.

## Building

Open `Thaw.xcodeproj` in Xcode 16.4 or newer and build the `Thaw` scheme. The built application is `Hoarfrost.app`.

## License

GNU GPLv3, the same license as Ice and Thaw. Copyright notices from both projects are preserved in the source. See [LICENSE](LICENSE).

## Thanks

- [Jordan Baird](https://github.com/jordanbaird) for creating Ice
- [Toni Förster](https://github.com/stonerl) and the Thaw contributors for keeping it alive and pushing it forward
- The Ice and Thaw translators, whose work is included here
