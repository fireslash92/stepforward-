# Step Forward If You Have…

A live 3D party game. One person is the **Question Master** and finishes the line *"Step forward if you have…"*. Everyone else secretly picks **Step forward** or **Stay**. On **Reveal!**, everyone who chose forward hops over the line.

- `index.html` — the browser game (three.js + Firebase Realtime Database). Hosted on GitHub Pages.
- `godot/` — the same game as a Godot 4 project (Sprite3D characters, WebSocket multiplayer).

## Playing

1. Open the game link. You get a room code (for example `#K7QD`).
2. Tap **Copy invite link** and send it to friends. Everyone with that link is in the same room.
3. One person taps **Be Question Master**, the rest tap **Join the stage**.

**Practice with bots** works offline.

## Turn on GitHub Pages

Repo **Settings → Pages → Build and deployment**: Source **Deploy from a branch**, branch **main**, folder **/ (root)**, then **Save**. After a minute the game is at `https://<username>.github.io/<repo>/`.

## Firebase setup

The config is in `index.html` (`window.FIREBASE_CONFIG`). These values are public by design.

1. Check `databaseURL`: in the Firebase console open **Realtime Database** and compare the address shown at the top of the **Data** tab. If yours ends in `firebasedatabase.app` (a non-US region), paste that address in instead.
2. Rules: test mode switches off after 30 days. Replace the rules (Realtime Database → **Rules**) with `database.rules.json` from this repo and **Publish**. They allow game data only under `games/` and limit text lengths.
