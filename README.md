<div align="center">
    <img src="Resources/Icon.svg" width=200 height=200>
    <h1>Hoarfrost</h1>
    <p>A different take on the menu bar manager: more than one hidden bar.</p>
</div>

![Platform](https://img.shields.io/badge/platform-macOS-blue?style=flat-square)
![Requirements](https://img.shields.io/badge/requirements-macOS%2014%2B-fa4e49?style=flat-square)
[![License](https://img.shields.io/badge/license-GPLv3-green?style=flat-square)](LICENSE)

> [!NOTE]
> Hoarfrost is a fork of [Thaw](https://github.com/thaw-app/Thaw) by Toni Förster, which is itself a fork of [Ice](https://github.com/jordanbaird/Ice) by Jordan Baird. Nearly everything here was built by them. Hoarfrost exists to try a different idea on top of that foundation. Both projects are excellent and you should probably use one of them today.

## The idea

Ice and Thaw give you one hidden section: click the divider and everything you tucked away comes back. That works until you have thirty menu bar icons and the hidden section is as cluttered as the menu bar was.

Hoarfrost lets you make as many groups as you want. Each group gets its own name, its own icon in the menu bar, its own hotkey, and its own way of showing up:

- **Push**: the classic Ice style horizontal expand
- **Bar**: a floating panel under the menu bar, like the Ice Bar
- **Menu**: a real dropdown, a menu bar app for your menu bar apps

Use one control icon with every group inside it, or one icon per group, or mix. The goal is that you can organize your menu bar the way you organize folders, and make it feel quick while doing it.

## Status

Early. Right now this is Thaw 1.3.0 beta 1 building on Xcode 16, plus a plan. See [TODO.md](TODO.md) for where it is going. Nothing is released yet.

Why Thaw 1.3 and not 2.0: Thaw 2.0 requires macOS 26. Hoarfrost keeps macOS 14 and 15 working alongside 26, so it starts from the last release that supported them and pulls forward what it can from 2.0.

## Building

Open `Thaw.xcodeproj` in Xcode 16.4 or newer and build the `Thaw` scheme. The project name and bundle identifiers will change to Hoarfrost once the core work lands, so upstream changes stay easy to merge until then.

## License

GNU GPLv3, the same license as Ice and Thaw. Copyright notices from both projects are preserved in the source. See [LICENSE](LICENSE).

## Thanks

- [Jordan Baird](https://github.com/jordanbaird) for creating Ice
- [Toni Förster](https://github.com/stonerl) and the Thaw contributors for keeping it alive and pushing it forward
- The Ice and Thaw translators, whose work is included here
