-- Offline-Test für Become1.lua.
--
-- Stubt die MoneyMoney-Laufzeit (WebBanking, Connection, JSON, Konstanten) und
-- fährt InitializeSession → ListAccounts → RefreshAccount gegen feste Fixtures.
-- Geprüft werden Betragsskalierung, Vorzeichen, Saldo, Pending-Handling und
-- Datums-Parsing — nicht die Netzwerkschicht.
--
-- Ausführen:  lua test/run_tests.lua

-- --------------------------------------------------------------------------
-- Fixtures (Struktur exakt wie von api.become1.de/graphql beobachtet)
-- --------------------------------------------------------------------------

local fixtures = {
  token = { id_token = 'eyJhbGciOiJSUzI1NiIsImtpZCI6InN0dWIifQ.stub.stub' },

  cardUsers = {
    data = {
      getOwnB1CardUsers = {
        { id = '11111111-2222-3333-4444-555555555555', cardStatus = 'ACTIVE' }
      }
    }
  },

  transactions = {
    data = {
      queryB1CardUserTransactions = {
        { id = 'tx-1', dateCreated = '2026-11-10T17:55:35.041Z', reference = 'SumUp  *Mama_s Haus',
          side = 'DEBIT',  isPending = true,  amount = { value = 1200, currency = 'EUR_CENT' } },
        { id = 'tx-2', dateCreated = '2026-11-03T08:12:00.000Z', reference = 'Golden Cut by Ivan',
          side = 'DEBIT',  isPending = false, amount = { value = 2500, currency = 'EUR_CENT' } },
        { id = 'tx-3', dateCreated = '2026-11-01T01:00:07.628Z', reference = 'Aufladung November',
          side = 'CREDIT', isPending = false, amount = { value = 5000, currency = 'EUR_CENT' } }
      }
    }
  }
}

-- --------------------------------------------------------------------------
-- MoneyMoney-Laufzeit stubben
-- --------------------------------------------------------------------------

ProtocolWebBanking  = 'ProtocolWebBanking'
AccountTypeCreditCard = 'AccountTypeCreditCard'
LoginFailed         = 'LoginFailed'

local requests = {}   -- Protokoll aller abgesetzten Requests

function WebBanking (spec)
  _G.__spec = spec
end

function Connection ()
  return {
    request = function (self, method, url, body, contentType, headers)
      requests[#requests + 1] = {
        method = method, url = url, body = body,
        contentType = contentType, headers = headers
      }

      if string.find(url, 'securetoken.googleapis.com', 1, true) then
        return 'FIXTURE:token'
      end
      if string.find(body or '', 'getOwnB1CardUsers', 1, true) then
        return 'FIXTURE:cardUsers'
      end
      if string.find(body or '', 'queryB1CardUserTransactions', 1, true) then
        return 'FIXTURE:transactions'
      end
      error('unerwarteter Request: ' .. url .. ' / ' .. tostring(body))
    end
  }
end

function JSON (str)
  local key = string.match(str or '', '^FIXTURE:(%w+)$')
  local value = key and fixtures[key] or {}
  return {
    dictionary = function () return value end
  }
end

-- --------------------------------------------------------------------------
-- Test-Helfer
-- --------------------------------------------------------------------------

local failures = 0

local function check (name, actual, expected)
  if actual ~= expected then
    failures = failures + 1
    print(string.format('FAIL  %s\n        erwartet: %s\n        bekommen: %s',
      name, tostring(expected), tostring(actual)))
  else
    print(string.format('ok    %s  (%s)', name, tostring(actual)))
  end
end

local function round (n)
  return math.floor(n * 100 + 0.5) / 100
end

-- --------------------------------------------------------------------------
-- Ablauf
-- --------------------------------------------------------------------------

dofile('Become1.lua')

check('SupportsBank: become.1', SupportsBank(ProtocolWebBanking, 'become.1'), true)
check('SupportsBank: fremde Bank', SupportsBank(ProtocolWebBanking, 'sevDesk'), false)

InitializeSession(ProtocolWebBanking, 'become.1', '', nil, 'refresh-token-stub')

check('Token-Request ist POST', requests[1].method, 'POST')
check('Token-Request Content-Type', requests[1].contentType, 'application/x-www-form-urlencoded')
check('Token-Request enthält grant_type',
  string.find(requests[1].body, 'grant_type=refresh_token', 1, true) ~= nil, true)
check('GraphQL sendet ID-Token roh (ohne Bearer)',
  requests[2].headers['Authorization'], fixtures.token.id_token)

local accounts = ListAccounts({})
check('ein Konto', #accounts, 1)
check('Kontoname Default', accounts[1].name, 'become.1 Card')
check('Kontonummer = B1Card-User-ID', accounts[1].accountNumber,
  '11111111-2222-3333-4444-555555555555')
check('Kontotyp', accounts[1].type, AccountTypeCreditCard)
check('Währung', accounts[1].currency, 'EUR')

local result = RefreshAccount(accounts[1], nil)
local tx = result.transactions

check('drei Buchungen', #tx, 3)
check('DEBIT wird negativ', round(tx[1].amount), -12.00)
check('Cent werden zu Euro', round(tx[2].amount), -25.00)
check('CREDIT bleibt positiv', round(tx[3].amount), 50.00)
check('pending ist nicht gebucht', tx[1].booked, false)
check('nicht-pending ist gebucht', tx[2].booked, true)
check('Händlertext als name', tx[1].name, 'SumUp  *Mama_s Haus')
check('Händlertext als purpose', tx[1].purpose, 'SumUp  *Mama_s Haus')
check('ID durchgereicht', tx[1].id, 'tx-1')

-- Saldo: gebucht = -25 + 50 = 25,00 / inkl. pending = 13,00
check('Saldo nur gebucht', round(result.balance), 25.00)
check('Saldo inkl. vorgemerkt', round(result.pendingBalance), 13.00)

-- Datum: 2026-11-03T08:12:00Z muss unabhängig von der lokalen Zeitzone
-- wieder als derselbe UTC-Zeitpunkt herauskommen.
check('Buchungsdatum als UTC geparst',
  os.date('!%Y-%m-%dT%H:%M:%S', tx[2].bookingDate), '2026-11-03T08:12:00')
check('valueDate = bookingDate', tx[2].valueDate, tx[2].bookingDate)

-- Eine Buchung in einer anderen Einheit darf nicht durch 100 geteilt werden.
fixtures.transactions.data.queryB1CardUserTransactions = {
  { id = 'tx-9', dateCreated = '2026-10-01T10:00:00.000Z', reference = 'Fremdwährung',
    side = 'DEBIT', isPending = false, amount = { value = 42, currency = 'CHF' } }
}
local other = RefreshAccount(accounts[1], nil)
check('unbekannte Einheit wird nicht skaliert', round(other.transactions[1].amount), -42.00)

EndSession()

print('')
if failures == 0 then
  print('Alle Tests bestanden.')
else
  print(failures .. ' Test(s) fehlgeschlagen.')
  os.exit(1)
end
