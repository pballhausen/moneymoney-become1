-- MoneyMoney WebBanking Extension für die become.1 Card
--
-- become.1 (https://become1.de) bietet keine öffentliche API. Diese Extension
-- nutzt dieselbe private GraphQL-API wie die Web-App unter https://app.become1.de.
--
-- Authentifizierung:
--   Die Web-App meldet sich über Firebase Auth an (Provider: Microsoft SSO).
--   Der SSO-Flow lässt sich in Lua nicht nachbauen, der langlebige Firebase
--   Refresh-Token aber schon: er wird einmalig aus dem Browser extrahiert und
--   hier als Passwort hinterlegt. Daraus holt die Extension bei jedem Login ein
--   frisches ID-Token (1 h gültig).
--
-- Login in MoneyMoney:
--   Bankleitzahl/Dienst: become.1
--   Benutzername:        optional ein eigener Kontoname (leer = "become.1 Card")
--   Passwort:            Firebase Refresh-Token (siehe README.md)

WebBanking{
  version     = 1.0,
  url         = 'https://api.become1.de/graphql',
  services    = {'become.1'},
  description = 'Ruft Saldo und Buchungen der become.1 Card ab'
}

local apiUrl      = 'https://api.become1.de/graphql'
local firebaseKey = 'AIzaSyCQmxu5BULN61MH-r2qCpryqas0rXkUVjE'  -- Web-API-Key des Firebase-Projekts become1-prod
local tokenUrl    = 'https://securetoken.googleapis.com/v1/token?key=' .. firebaseKey

local connection
local idToken
local accountName
local cardUserId

-- ---------------------------------------------------------------------------
-- Hilfsfunktionen
-- ---------------------------------------------------------------------------

local function urlencode (str)
  return (string.gsub(str, '[^%w%-%_%.%~]', function (c)
    return string.format('%%%02X', string.byte(c))
  end))
end

-- ISO-8601-Zeitstempel in UTC ("2026-11-10T17:55:35.041Z") in Unix-Timestamp wandeln
local function parseTimestamp (str)
  if not str then return nil end
  local y, mo, d = string.match(str, '(%d%d%d%d)%-(%d%d)%-(%d%d)')
  if not y then return nil end
  local h, mi, s = string.match(str, 'T(%d%d):(%d%d):(%d%d)')

  local fields = {
    year  = tonumber(y),
    month = tonumber(mo),
    day   = tonumber(d),
    hour  = tonumber(h) or 12,
    min   = tonumber(mi) or 0,
    sec   = tonumber(s) or 0,
    isdst = false
  }

  -- os.time interpretiert die Felder als Lokalzeit. Die Differenz zur
  -- UTC-Interpretation derselben Felder ist der Offset, den wir addieren.
  local asLocal = os.time(fields)
  if not asLocal then return nil end
  local offset = os.difftime(asLocal, os.time(os.date('!*t', asLocal)))
  return asLocal + offset
end

-- GraphQL-Anfrage gegen api.become1.de, gibt den data-Teil zurück
local function graphql (query)
  local headers = {
    ['Authorization'] = idToken,   -- die Web-App sendet das JWT ohne "Bearer "-Präfix
    ['Accept']        = 'application/json'
  }
  -- Body von Hand bauen: die Queries hier enthalten keine Anführungszeichen,
  -- Zeilenumbrüche werden zu Leerzeichen.
  local escaped  = (string.gsub(string.gsub(query, '"', '\\"'), '%s+', ' '))
  local body     = '{"query":"' .. escaped .. '"}'
  local response = connection:request('POST', apiUrl, body, 'application/json', headers)
  local json     = JSON(response):dictionary()

  if json['errors'] then
    local first = json['errors'][1] or {}
    error('become.1 API-Fehler: ' .. tostring(first['message'] or 'unbekannt') ..
          ' (' .. tostring(first['exceptionCode'] or '') .. ')')
  end

  return json['data'] or {}
end

-- Refresh-Token gegen ein frisches Firebase-ID-Token tauschen
local function refreshIdToken (refreshToken)
  local body = 'grant_type=refresh_token&refresh_token=' .. urlencode(refreshToken)
  local response = connection:request(
    'POST', tokenUrl, body, 'application/x-www-form-urlencoded',
    {['Accept'] = 'application/json'}
  )

  local json = JSON(response):dictionary()
  if not json['id_token'] then
    return nil
  end
  return json['id_token']
end

-- ---------------------------------------------------------------------------
-- MoneyMoney-Schnittstelle
-- ---------------------------------------------------------------------------

function SupportsBank (protocol, bankCode)
  return bankCode == 'become.1' and protocol == ProtocolWebBanking
end

function InitializeSession (protocol, bankCode, username, reserved, password)
  connection = Connection()

  accountName = (username and username ~= '') and username or 'become.1 Card'

  if not password or password == '' then
    error('Kein Refresh-Token angegeben. Siehe README.md zum Auslesen aus dem Browser.')
  end

  -- Ein abgelaufener oder zurückgezogener Refresh-Token liefert hier einen
  -- 400er; Firebase-Fehler kommen als HTTP-Fehler bei connection:request an.
  local ok, token = pcall(refreshIdToken, password)
  if not ok or not token then
    if LoginFailed ~= nil then
      return LoginFailed
    end
    error('Login fehlgeschlagen: Der Refresh-Token ist ungültig oder abgelaufen. ' ..
          'Bitte neu aus dem Browser auslesen (siehe README.md).')
  end

  idToken = token

  -- Verbindung testen und die stabile ID des Karten-Nutzers merken
  local data  = graphql('{ getOwnB1CardUsers { id cardStatus } }')
  local users = data['getOwnB1CardUsers'] or {}
  if #users > 0 then
    cardUserId = users[1]['id']
  end
end

function ListAccounts (knownAccounts)
  return {
    {
      name          = accountName,
      accountNumber = cardUserId or 'become1-card',
      currency      = 'EUR',
      type          = AccountTypeCreditCard
    }
  }
end

function RefreshAccount (account, since)
  local data = graphql([[
    query B1CardTransactions {
      queryB1CardUserTransactions {
        id
        dateCreated
        reference
        side
        isPending
        amount { value currency }
      }
    }
  ]])

  local transactions   = {}
  local bookedBalance  = 0
  local pendingBalance = 0

  for _, t in ipairs(data['queryB1CardUserTransactions'] or {}) do
    local money    = t['amount'] or {}
    local currency = money['currency']
    local value    = tonumber(money['value']) or 0

    -- become.1 liefert Beträge als Ganzzahl in Cent (currency = "EUR_CENT")
    local amount = value / 100
    if currency and currency ~= 'EUR_CENT' then
      -- Unbekannte Einheit: lieber unverändert durchreichen als falsch skalieren
      amount = value
    end

    -- DEBIT = Zahlung (Abgang), CREDIT = Aufladung (Zugang)
    if t['side'] == 'DEBIT' then
      amount = -amount
    end

    local booked = (t['isPending'] ~= true)
    local ts     = parseTimestamp(t['dateCreated'])

    if booked then
      bookedBalance = bookedBalance + amount
    else
      pendingBalance = pendingBalance + amount
    end

    transactions[#transactions + 1] = {
      name        = t['reference'] or '',
      purpose     = t['reference'] or '',
      amount      = amount,
      currency    = 'EUR',
      bookingDate = ts,
      valueDate   = ts,
      booked      = booked,
      id          = t['id']
    }
  end

  return {
    balance        = bookedBalance,
    pendingBalance = bookedBalance + pendingBalance,
    transactions   = transactions
  }
end

function EndSession ()
  idToken = nil
end
