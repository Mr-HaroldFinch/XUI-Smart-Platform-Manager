# راهنمای قرار دادن اسکریپت در GitHub

مثال‌ها از `Mr-HaroldFinch/XUI-Smart-Platform-Manager` استفاده می‌کنند. `publish.sh` آن‌ها را با نام واقعی شما جایگزین می‌کند.

## ۱. ساخت مخزن
1. وارد github.com شوید (حساب نداشتید، بسازید و ایمیل را تأیید کنید؛ فعال‌کردن 2FA را از Settings -> Password and authentication انجام دهید).
2. **New repository** بزنید.
3. نام مثلاً `moc-xui-manager`. نوع را **Public** بگذارید (برای لینک raw و به‌روزرسانی خودکار بدون توکن لازم است).
4. گزینه‌های *Add a README*، *.gitignore* و *license* را **تیک نزنید** (این فایل‌ها آماده‌اند).

## ۲. آماده‌سازی فایل‌ها روی کامپیوتر
پوشهٔ بسته را باز کنید و (در لینوکس / macOS / WSL / Git Bash) اجرا کنید:

```bash
./publish.sh Mr-HaroldFinch XUI-Smart-Platform-Manager        # نام کاربری GitHub و نام مخزن
```

این دستور:
- آدرس raw را داخل اسکریپت می‌نویسد (منوی «به‌روزرسانی همین اسکریپت» بدون پرسش کار می‌کند)؛
- لینک‌های README را اصلاح می‌کند؛
- `bash -n` و `shellcheck` را اجرا می‌کند؛
- فایل‌های هش `XUI-SPM.sh.sha256` و `SHA256SUMS` و متن `RELEASE_NOTES.md` را می‌سازد و درستی هش را بررسی می‌کند.

اگر Windows بدون Bash دارید: بدون اجرای `publish.sh` هم می‌شود (فایل‌ها همین الان هش درست دارند)، فقط اولین بار در منوی اسکریپت آدرس raw را وارد کنید.

> **قانون مهم:** هر بار که حتی یک حرف از `XUI-SPM.sh` را تغییر دادید، دوباره `./publish.sh` را اجرا کنید. هش باید همیشه با فایل بخواند، وگرنه به‌روزرسانی خودکار «Checksum does NOT match» می‌دهد و نصب را رد می‌کند (و CI قرمز می‌شود).

## ۳. بارگذاری (یکی از چهار روش)

### روش الف - با git (پیشنهادی)
```bash
cd moc-xui-manager
git init -b main
git add -A
git commit -m "v1.2026.11.4"
git remote add origin https://github.com/Mr-HaroldFinch/XUI-Smart-Platform-Manager.git
git push -u origin main
```
هنگام push نام کاربری و **Personal Access Token** می‌خواهد (رمز حساب کار نمی‌کند): GitHub -> Settings -> Developer settings -> Personal access tokens -> Fine-grained token، دسترسی *Contents: Read and write* فقط برای همین مخزن. یا با `gh auth login` وارد شوید.

### روش ب - فقط با مرورگر GitHub (بدون نصب هیچ برنامه‌ای؛ مناسب ویندوز)
۱. فایل `moc-xui-manager.zip` را روی کامپیوتر **Extract** کنید (راست‌کلیک -> Extract All).
۲. مخزن خالی را که ساخته‌اید باز کنید. وسط صفحه لینک **uploading an existing file** را بزنید (یا **Add file -> Upload files**).
۳. از پوشهٔ استخراج‌شده **همهٔ محتویات** را انتخاب کنید (`Ctrl+A`) و بکشید داخل صفحهٔ GitHub. پوشه‌های `.github` و `docs` و فایل‌های `.gitignore` و `.gitattributes` هم باید باشند. اگر یکی از فایل‌های نقطه‌دار دیده نشد، در File Explorer از View -> Show -> Hidden items را روشن کنید.
۴. پایین صفحه در **Commit changes** پیام `v1.2026.11.4` را بنویسید، گزینهٔ *Commit directly to the main branch* را نگه دارید و **Commit changes** را بزنید.
۵. صبر کنید آپلود تمام شود (نوار سبز)، سپس صفحهٔ مخزن را تازه کنید و مطمئن شوید این فایل‌ها هستند: `XUI-SPM.sh`، `XUI-SPM.sh.sha256`، `SHA256SUMS`، `README.md`، `.github/workflows/check.yml`.
۶. تب **Actions** را باز کنید: اگر `check` سبز شد یعنی نحو، shellcheck و هش درست‌اند.
۷. سراغ مرحلهٔ ۴ (Release) بروید؛ آن هم کاملاً از مرورگر انجام می‌شود.

> بدون اجرای `publish.sh` هم همه‌چیز کار می‌کند: هش‌های داخل بسته همین حالا درست‌اند. تنها تفاوت این است که آدرس به‌روزرسانی داخل اسکریپت خالی است و اولین بار در منوی «به‌روزرسانی همین اسکریپت» باید این لینک را وارد کنید (یک بار، بعد خودش یادش می‌ماند):
> `https://raw.githubusercontent.com/نام‌کاربری/نام‌مخزن/main/XUI-SPM.sh`
> لینک‌های `Mr-HaroldFinch/XUI-Smart-Platform-Manager` داخل README را هم می‌شود در خود GitHub با دکمهٔ مداد (Edit) اصلاح کرد؛ فایل `XUI-SPM.sh` را به‌هیچ‌وجه با مداد ویرایش نکنید، چون هش به‌هم می‌خورد.

### روش ج - ویندوز با GitHub Desktop (رابط گرافیکی)
۱. از desktop.github.com برنامه را نصب کنید و با حساب GitHub وارد شوید.
۲. **File -> New repository**: Name = `moc-xui-manager`، Local path = پوشه‌ای که می‌خواهید، *Initialize with README* را **تیک نزنید**، **Create repository**.
۳. محتویات زیپ استخراج‌شده را داخل پوشهٔ ساخته‌شدهٔ مخزن کپی کنید (فایل‌های نقطه‌دار هم).
۴. در GitHub Desktop همهٔ فایل‌ها در ستون چپ دیده می‌شوند. پایین چپ در *Summary* بنویسید `v1.2026.11.4` و **Commit to main** را بزنید.
۵. **Publish repository** را بزنید. تیک *Keep this code private* را **بردارید** (باید Public باشد) و Publish کنید.
۶. برای نسخه‌های بعدی: فایل را جایگزین کنید، commit کنید و **Push origin** بزنید.

### روش د - ویندوز با Git for Windows و PowerShell
۱. از git-scm.com نصب کنید. در پوشهٔ بسته، راست‌کلیک -> *Open Git Bash here*. حالا همان دستورهای روش الف و `./publish.sh` کار می‌کنند.
۲. اگر ترجیح می‌دهید فقط PowerShell داشته باشید، هش را این‌طور بسازید و بررسی کنید:

```powershell
cd C:\path\to\moc-xui-manager
$h = (Get-FileHash .\XUI-SPM.sh -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText("$PWD\XUI-SPM.sh.sha256", "$h  XUI-SPM.sh`n")   # بدون BOM و با LF
Copy-Item XUI-SPM.sh.sha256 SHA256SUMS
Get-FileHash .\XUI-SPM.sh -Algorithm SHA256    # باید با محتوای فایل .sha256 یکی باشد
```

### هشدار مهم ویندوز: پایان خط (CRLF)
اسکریپت باید با پایان خط **LF** ذخیره شود. اگر آن را در Notepad قدیمی یا ویرایشگری که به CRLF تبدیل می‌کند ذخیره کنید، روی لینوکس خطای `bad interpreter` یا `\r: command not found` می‌دهد و هش هم عوض می‌شود. فایل `.gitattributes` این بسته git را وادار می‌کند `.sh` را با LF نگه دارد، اما بهتر است فایل را روی ویندوز اصلاً ویرایش نکنید. اگر مجبورید، از VS Code استفاده کنید و پایین سمت راست روی `CRLF` کلیک و `LF` را انتخاب کنید. بعد از هر تغییر هش را دوباره بسازید.

## ۴. ساخت Release با هش (برای اطمینان خوانندگان)
1. صفحهٔ مخزن -> **Releases -> Create a new release**.
2. Tag: `v1.2026.11.4` (Create new tag on publish)، عنوان: `v1.2026.11.4`.
3. متن را از فایل `RELEASE_NOTES.md` کپی کنید (هش داخل آن است).
4. فایل‌های `XUI-SPM.sh`، `XUI-SPM.sh.sha256` و `SHA256SUMS` را در بخش *Attach binaries* بکشید.
5. **Publish release**.

هش در سه جا منتشر می‌شود: کنار فایل در مخزن، در Release و در متن Release؛ اگر کسی فایل را دستکاری کند، با هر کدام می‌توان فهمید.

## ۵. بررسی لینک‌ها
بعد از چند دقیقه روی یک سرور تستی:

```bash
curl -fsSLO https://raw.githubusercontent.com/Mr-HaroldFinch/XUI-Smart-Platform-Manager/main/XUI-SPM.sh
curl -fsSLO https://raw.githubusercontent.com/Mr-HaroldFinch/XUI-Smart-Platform-Manager/main/XUI-SPM.sh.sha256
sha256sum -c XUI-SPM.sh.sha256
```
باید `XUI-SPM.sh: OK` ببینید. سپس `sudo bash XUI-SPM.sh --check-update`.

> GitHub آدرس raw را تا حدود ۵ دقیقه کش می‌کند؛ بعد از push فوراً تغییر را نمی‌بینید.

## ۶. انتشار نسخهٔ بعدی
1. در `XUI-SPM.sh` عدد `VER_SUB` را بالا ببرید (مثلاً ۳ -> ۴).
2. `CHANGELOG.md` را به‌روز کنید.
3. `./publish.sh` (بدون آرگومان کافی است).
4. `git add -A && git commit -m "v1.2026.11.4" && git push`
5. `git tag v1.2026.11.4 && git push origin v1.2026.11.4` و یک Release جدید مثل مرحلهٔ ۴.

کاربران با «به‌روزرسانی همین اسکریپت» نسخهٔ جدید را می‌گیرند؛ اسکریپت قبل از نصب نحو، نام برنامه و هش را بررسی و نسخهٔ قبلی را به‌صورت `.bak` نگه می‌دارد.

## ۷. نکات
- **لایسنس:** فایل `LICENSE` را MIT گذاشته‌ام؛ اگر شرط دیگری می‌خواهید تغییرش دهید یا حذفش کنید.
- **اطلاعات حساس:** هرگز فایل پشتیبان (`XUI_Backup_*`)، `servers.dat` یا توکن را commit نکنید (در `.gitignore` هست).
- **دسترسی از ایران:** گاهی raw.githubusercontent.com کند یا مسدود است. آینه‌ای مثل `https://cdn.jsdelivr.net/gh/Mr-HaroldFinch/XUI-Smart-Platform-Manager@main/XUI-SPM.sh` را می‌توانید در README بگذارید؛ هش همان است. در اسکریپت هم `MOC_UPDATE_URL` آدرس دیگری را می‌پذیرد.
- **امنیت حساب:** 2FA را فعال کنید و Release را فقط از حساب خودتان منتشر کنید؛ چون اسکریپت با root اجرا می‌شود، کنترل مخزن یعنی کنترل سرورهای کاربران.
- در Settings -> Branches می‌توانید branch `main` را حفاظت کنید تا بدون CI سبز ادغام نشود.
