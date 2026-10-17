// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct T3ConnectStrings {
    let language: AppLanguage
    init(_ language: AppLanguage) { self.language = language }

    private var words: (signIn: String, signOut: String, refresh: String, cancel: String, browser: String,
                        waiting: String, empty: String, help: String, failure: String, expired: String, manual: String) {
        switch language {
        case .enUS: ("Sign in to T3 Connect", "Sign out", "Refresh machines", "Cancel", "Open browser",
            "Approve sign-in in your browser. Confirm this code:", "No machines linked to this account.",
            "Choose machines after signing in. Agent access is read-only. This app stores its own credentials.",
            "Could not complete sign-in. Try again.", "Sign-in code expired. Try again.", "Or pair an endpoint manually")
        case .ru: ("Войти в T3 Connect", "Выйти", "Обновить список машин", "Отмена", "Открыть браузер",
            "Подтвердите вход в браузере. Проверьте код:", "К этому аккаунту не привязаны машины.",
            "После входа выберите машины. Доступ к агентам — только для чтения. Приложение хранит отдельные учётные данные.",
            "Не удалось войти. Попробуйте ещё раз.", "Код входа истёк. Попробуйте ещё раз.", "Или подключите адрес вручную")
        case .uk: ("Увійти в T3 Connect", "Вийти", "Оновити машини", "Скасувати", "Відкрити браузер",
            "Підтвердьте вхід у браузері. Перевірте код:", "До цього облікового запису не прив’язано машин.",
            "Після входу виберіть машини. Доступ до агентів лише для читання. Програма зберігає окремі облікові дані.",
            "Не вдалося увійти. Спробуйте ще раз.", "Код входу прострочено. Спробуйте ще раз.", "Або підключіть адресу вручну")
        case .ptBR: ("Entrar no T3 Connect", "Sair", "Atualizar máquinas", "Cancelar", "Abrir navegador",
            "Aprove o acesso no navegador. Confirme este código:", "Nenhuma máquina vinculada a esta conta.",
            "Escolha máquinas após entrar. O acesso aos agentes é somente leitura. Este app guarda credenciais próprias.",
            "Não foi possível entrar. Tente novamente.", "O código expirou. Tente novamente.", "Ou emparelhe um endereço manualmente")
        case .de: ("Bei T3 Connect anmelden", "Abmelden", "Rechner aktualisieren", "Abbrechen", "Browser öffnen",
            "Anmeldung im Browser bestätigen. Diesen Code prüfen:", "Mit diesem Konto sind keine Rechner verknüpft.",
            "Nach der Anmeldung Rechner auswählen. Agentenzugriff ist schreibgeschützt. Diese App speichert eigene Zugangsdaten.",
            "Anmeldung fehlgeschlagen. Erneut versuchen.", "Anmeldecode abgelaufen. Erneut versuchen.", "Oder eine Adresse manuell koppeln")
        case .fr: ("Se connecter à T3 Connect", "Se déconnecter", "Actualiser les machines", "Annuler", "Ouvrir le navigateur",
            "Autorisez la connexion dans le navigateur. Vérifiez ce code :", "Aucune machine liée à ce compte.",
            "Choisissez les machines après connexion. Accès aux agents en lecture seule. Cette app conserve ses propres identifiants.",
            "Connexion impossible. Réessayez.", "Le code a expiré. Réessayez.", "Ou associer une adresse manuellement")
        case .es: ("Iniciar sesión en T3 Connect", "Cerrar sesión", "Actualizar máquinas", "Cancelar", "Abrir navegador",
            "Autoriza el acceso en el navegador. Confirma este código:", "No hay máquinas vinculadas a esta cuenta.",
            "Elige las máquinas tras iniciar sesión. Acceso a agentes de solo lectura. Esta app guarda sus propias credenciales.",
            "No se pudo iniciar sesión. Inténtalo de nuevo.", "El código caducó. Inténtalo de nuevo.", "O vincula una dirección manualmente")
        case .it: ("Accedi a T3 Connect", "Esci", "Aggiorna macchine", "Annulla", "Apri browser",
            "Autorizza l’accesso nel browser. Conferma questo codice:", "Nessuna macchina collegata a questo account.",
            "Scegli le macchine dopo l’accesso. Accesso agli agenti in sola lettura. Questa app conserva credenziali proprie.",
            "Accesso non riuscito. Riprova.", "Il codice è scaduto. Riprova.", "Oppure associa un indirizzo manualmente")
        case .tr: ("T3 Connect’e giriş yap", "Çıkış yap", "Makineleri yenile", "İptal", "Tarayıcıyı aç",
            "Tarayıcıda girişi onaylayın. Bu kodu doğrulayın:", "Bu hesaba bağlı makine yok.",
            "Girişten sonra makineleri seçin. Ajan erişimi salt okunurdur. Bu uygulama kendi kimlik bilgilerini saklar.",
            "Giriş tamamlanamadı. Yeniden deneyin.", "Giriş kodunun süresi doldu. Yeniden deneyin.", "Veya bir adresi elle eşleştirin")
        case .sk: ("Prihlásiť sa do T3 Connect", "Odhlásiť sa", "Obnoviť stroje", "Zrušiť", "Otvoriť prehliadač",
            "Potvrďte prihlásenie v prehliadači. Skontrolujte kód:", "S týmto účtom nie sú prepojené žiadne stroje.",
            "Po prihlásení vyberte stroje. Prístup k agentom je iba na čítanie. Aplikácia ukladá vlastné prihlasovacie údaje.",
            "Prihlásenie zlyhalo. Skúste znova.", "Platnosť kódu vypršala. Skúste znova.", "Alebo spárujte adresu ručne")
        case .ja: ("T3 Connect にサインイン", "サインアウト", "マシンを更新", "キャンセル", "ブラウザを開く",
            "ブラウザでサインインを承認し、このコードを確認してください：", "このアカウントにリンクされたマシンはありません。",
            "サインイン後にマシンを選択します。エージェントへのアクセスは読み取り専用です。このアプリ独自の認証情報を保存します。",
            "サインインできませんでした。再試行してください。", "コードの有効期限が切れました。再試行してください。", "またはアドレスを手動でペアリング")
        case .ko: ("T3 Connect 로그인", "로그아웃", "머신 새로 고침", "취소", "브라우저 열기",
            "브라우저에서 로그인을 승인하고 코드를 확인하세요:", "이 계정에 연결된 머신이 없습니다.",
            "로그인 후 머신을 선택하세요. 에이전트 접근은 읽기 전용이며 이 앱은 별도의 자격 증명을 저장합니다.",
            "로그인하지 못했습니다. 다시 시도하세요.", "코드가 만료되었습니다. 다시 시도하세요.", "또는 주소를 직접 페어링")
        case .zhHans: ("登录 T3 Connect", "退出登录", "刷新机器", "取消", "打开浏览器",
            "请在浏览器中批准登录并核对此代码：", "此账号尚未关联机器。",
            "登录后选择机器。代理访问为只读，此应用单独保存凭据。",
            "无法完成登录，请重试。", "登录代码已过期，请重试。", "或手动配对地址")
        case .zhTW, .zhHK: ("登入 T3 Connect", "登出", "重新整理機器", "取消", "開啟瀏覽器",
            "請在瀏覽器中核准登入並核對此代碼：", "此帳號尚未連結機器。",
            "登入後選擇機器。代理存取為唯讀，此應用程式獨立儲存憑證。",
            "無法完成登入，請重試。", "登入代碼已過期，請重試。", "或手動配對位址")
        }
    }

    var signIn: String { words.signIn }
    var signOut: String { words.signOut }
    var refresh: String { words.refresh }
    var cancel: String { words.cancel }
    var browser: String { words.browser }
    var waiting: String { words.waiting }
    var empty: String { words.empty }
    var help: String { words.help }
    var manual: String { words.manual }

    func error(_ error: T3ConnectError) -> String {
        switch error {
        case .expired: words.expired
        case .keychainUnavailable: T3CodeStrings(language).errors(.credentialStoreUnavailable(0))
        case .unavailable: T3CodeStrings(language).errors(.serverUnavailable)
        default: words.failure
        }
    }
}
