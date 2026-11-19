# Publish the Walker pages on kringum.is

You are on the server that hosts kringum.is. This package holds two static pages for the iPhone app **Walker – Explore your city**. Apple requires both before the app can go on the App Store:

| Page | Should be served at | File in this package |
|---|---|---|
| Support page | `https://kringum.is/walker/` | `walker/index.html` |
| Privacy policy | `https://kringum.is/walker/privacy/` | `walker/privacy/index.html` |

`walker/` also holds `style.css`, `icon.png` and `apple-touch-icon.png`. Everything is plain static HTML: no build step, no scripts, no server-side code.

The goal is to make those two URLs work, without disturbing anything else on the server.

## Steps

1. **Find out how kringum.is is served.** Don't guess. Look at the running web server and its configuration:
   - nginx: `nginx -T`
   - Apache: `apachectl -S`
   - Caddy: the Caddyfile
   - or whatever else is in use

   Find the server block or virtual host for `kringum.is` and its document root. If the site is a CMS such as WordPress, or a proxy to an app, check whether files in the document root are served directly. They usually are, before the rewrite rules apply. Tell the user what you found.

2. **Check for clashes.** If `<docroot>/walker` already exists, or `/walker` is already a route on the site, stop and ask the user what to do. Don't overwrite it.

3. **Fill in the contact email.** Both pages contain the placeholder `__CONTACT_EMAIL__`.
   - Ask the user which email address to show, and don't invent one.
   - Replace every occurrence in both files, for example:
     ```bash
     sed -i 's/__CONTACT_EMAIL__/name@example.com/g' walker/index.html walker/privacy/index.html
     ```
   - Then check that `grep -r __CONTACT_EMAIL__ walker` finds nothing.

4. **Copy the folder** to `<docroot>/walker`. Match the ownership and permissions of the files already in the document root: typically directories 755 and files 644, owned like their neighbours. Make sure the web server user can read them.

5. **Only if the URLs don't work as plain files,** a configuration change may be needed. That could be a `location` block, or an exception for `/walker` in a CMS or proxy setup.
   - Show the user the exact change and wait for their go-ahead.
   - Then back up the file, test the configuration (for example `nginx -t` or `apachectl configtest`) before reloading, and reload rather than restart.
   - Don't touch other sites or any other settings.

6. **Verify from the outside:**
   ```bash
   curl -sI https://kringum.is/walker/
   curl -sI https://kringum.is/walker/privacy/
   curl -sI https://kringum.is/walker/privacy
   curl -sI https://kringum.is/walker/style.css
   curl -sI https://kringum.is/walker/icon.png
   ```
   - The pages should return `200` with `Content-Type: text/html`.
   - `/walker/privacy` without the slash should redirect to `/walker/privacy/` or return `200`.
   - The stylesheet should be `text/css` and the icon `image/png`.
   - HTTPS must work with a valid certificate. Apple rejects privacy URLs that don't load.
   - The pages must be public, with no login or other access restriction.

7. **Report back** to the user with the two final URLs, any changes you made outside `<docroot>/walker`, and anything you weren't sure about.

## Later updates

The pages' source lives in the Walker app's repository (`site/walker/`). A new package replaces the whole `<docroot>/walker` folder. Keep the contact email the user chose: fill the placeholder in again, the same way as in step 3.
