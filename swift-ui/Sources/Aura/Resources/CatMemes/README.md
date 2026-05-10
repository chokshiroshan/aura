# Cat Meme Reactions

Drop hand-curated cat images into the matching subfolder. The
`MemeReactionEngine` picks a random one per trigger and avoids repeating the
same image twice in a row.

| Folder      | Fires when                                         | Suggested vibe                  |
| ----------- | -------------------------------------------------- | ------------------------------- |
| `success/`  | A tool call completes (Aura did something useful)  | Smug / triumphant / fist-bump   |
| `error/`    | An error event or failed turn                      | Confused / dejected / shrug     |
| `startled/` | User yells over Aura while it's speaking           | Wide-eyed / jump-scare cat      |
| `bored/`    | 3+ minutes of continuous idle                      | Sleepy loaf / yawn / stretch    |

Supported formats: `.png`, `.gif`, `.jpg`, `.jpeg`. Transparent backgrounds
are recommended. Animated GIFs render via `NSImageView` and animate
natively. 3–5 images per category is a good starting point.

The folder names are case-sensitive and must match the engine's `Category`
raw values exactly.
