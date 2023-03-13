(namespace 'free)
(define-keyset "free.domain-admin-gov-keyset" (read-keyset 'domain-admin-gov-keyset))

(module testingdomain GOVERNANCE

  ; --------------------------------------------------------------------------
  ; Schemas and Tables

  ; subdomain-schema
  (defschema subdomain
    name:string
    address:string
  )

  ;define names schema
  (defschema names
    owner:string
    lastPrice:decimal
    expiryDate:time
    subdomains:list
  )

  ;define name map schema
  (defschema name-map
    address:string
    top-level-name:string
  )

  ;define address map schema
  (defschema address-map
    name:string
    top-level-name:string
  )

  ;define sales schema
  (defschema sales
    price:decimal
    sellable:bool
  )

  (deftable names-table:{names})
  (deftable name-map-table:{name-map})
  (deftable address-map-table:{address-map})
  (deftable sales-table:{sales})

  ; --------------------------------------------------------------------------
  ; Constants

  (defconst BASE_ONEYEAR_PRICE 1.0)
  (defconst BASE_TWOYEAR_PRICE (* (* BASE_ONEYEAR_PRICE 2) 0.95))
  (defconst SUBDOMAIN_PRICE 3.0)
  (defconst UPDATE_PRICE 0.5)
  (defconst SELL_FEE_PERCENTAGE 5.0)
  (defconst EXPIRATION_GRACE_PERIOD 31)
  (defconst VAULT_ACCOUNT "k:36990b871267ec4532551e505260806d7f39378cebb5ea2c998c80301c5a100f")

  (defconst ALLOWED_CHARS:list ["-", "_", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"])

  ; --------------------------------------------------------------------------
  ; Utils

  (defun curr-time:time ()
    @doc "Returns current chain's block-time in time type"
    (at 'block-time (chain-data)))


  ; --------------------------------------------------------------------------
  ; Capabilities

  (use coin [ details transfer ])

  (defcap GOVERNANCE ()
    "Module governance capability that only allows the admin to update this module"
    ;; Check if the tx was signed with the provided keyset, fail if not
    (enforce-keyset "free.doamin-admin-gov-keyset"))

  (defcap ACCOUNT_GUARD (account)
    (enforce-guard (at 'guard (coin.details account)))
  )

  (defcap NAME_AVAILABLE (name:string)
    @doc "Validate if the name is available "

    (with-default-read names-table name
      { "expiryDate": (add-time (curr-time) (days (* -1 EXPIRATION_GRACE_PERIOD))) }
      { "expiryDate":= expiryDate }

      (enforce (>= (curr-time) (add-time expiryDate (days EXPIRATION_GRACE_PERIOD))) "Name not available")
    )
  )

  (defcap NAME_UPSERT (name:string)
    "New name has been added or updated"
    @event
    true
  )

  (defcap ITEM_SOLD (name:string prevOwner:string newOwner:string price:decimal)
    "An item has been sold"
    @event
    true
  )

  (defcap SALE_STATUS_UPDATED (name:string)
    "An item has been put up for and removed from sale"
    @event
    true
  )

  (defcap MAPPING () true)

  ; --------------------------------------------------------------------------
  ; Functions

  (defun enforce-domain (name:string)
    (enforce (= ".kda" (take -4 name)) "Domain should be .kda")
  )

  (defun strip-domain (name:string)
    (drop -4 name)
  )

  (defun enforce-name-is-valid (name:string)
    (enforce (<= (length name) 35) "Maximum 35 characters allowed in name")
    (enforce (!= name "") "Name should not be empty")
    (let*
      (
        (validate-character (lambda (character)
          (enforce (= true (contains character ALLOWED_CHARS)) "No forbidden chars allowed")
        ))
      )
      (map (validate-character) (str-to-list name))
    )
  )

  (defun enforce-active-registration (expiryDate:time)
   (enforce (<= (curr-time) expiryDate) "Registration expired")
  )

  (defun enforce-address-is-valid (address: string)
    (enforce-one "Only k: and w: accounts are supported" [
      (enforce (= (take 2 address) "k:") "k:account")
      (enforce (= (take 2 address) "w:") "w:account")
    ])
  )

  (defun enforce-days-is-valid (nrDays:integer)
   (enforce-one "Invalid days" [
     (enforce (= nrDays 365) "One year")
     (enforce (= nrDays 730) "Two years")
   ])
  )

  (defun enforce-address-not-in-use (address: string)
    (with-default-read address-map-table address
      {
        "name" : "",
        "top-level-name" : ""
      }
      {
        "name" := name,
        "top-level-name" := toplevelname
      }

      (with-default-read names-table toplevelname
        { "expiryDate": (add-time (curr-time) (days (* -1 EXPIRATION_GRACE_PERIOD))) }
        { "expiryDate":= expiryDate }

        (enforce-one "Address already in use" [
          (enforce (= name "") "Name is an empty string, so mapping doesn't exist")
          (enforce (>= (curr-time) (add-time expiryDate (days EXPIRATION_GRACE_PERIOD))) "Address map exists but domain has expired")
        ])
      )
    )
  )

  (defun get-price (days:integer)
   (if (= days 365) BASE_ONEYEAR_PRICE BASE_TWOYEAR_PRICE)
  )

  (defun set-mappings (fqn:string toplevelname:string address:string)
    (require-capability (MAPPING))
    (write name-map-table fqn {
      "address": address,
      "top-level-name": toplevelname
    })
    (write address-map-table address {
      "name": fqn,
      "top-level-name": toplevelname
    })
  )

  (defun remove-mappings (fqn:string)
    (require-capability (MAPPING))
    (with-read name-map-table fqn
      {
        "address":= address
      }

      (write name-map-table fqn {
        "address": "",
        "top-level-name": ""
      })

      (write address-map-table address {
        "name": "",
        "top-level-name": ""
      })
    )
  )

  (defun register (owner:string address:string name:string nrDays:integer)
    (enforce-domain name)
    (enforce-name-is-valid (strip-domain name))
    (enforce-days-is-valid nrDays)
    (enforce-address-is-valid address)
    (enforce-address-not-in-use address)

    (with-capability (NAME_AVAILABLE name)
    (with-capability (ACCOUNT_GUARD owner)
    (with-capability (NAME_UPSERT name)
    (with-capability (MAPPING)

      (coin.transfer owner VAULT_ACCOUNT (get-price nrDays))

      ; Clear existing subdomain mapping if available
      (with-default-read names-table name
        { "subdomains": [] }
        { "subdomains":= subdomains }


        (map (remove-mappings) subdomains)
      )

      ; write name information
      (write names-table name {
        "owner": owner,
        "lastPrice": (get-price nrDays),
        "expiryDate": (add-time (curr-time) (days nrDays)),
        "subdomains": []
      })

      ; Set mappings
      (set-mappings name name address)

      ;  Clear open sell order if available
      (with-default-read sales-table name
        { "sellable": false }
        { "sellable":= sellable }

        (if sellable (update sales-table name { "sellable": false }) true)
      )
    ))))
  )

  (defun register-subdomain (address:string name:string subdomain:string)
    (enforce-name-is-valid subdomain)
    (enforce-address-is-valid address)
    (enforce-address-not-in-use address)

    (with-read names-table name
      {
        "owner":= owner,
        "expiryDate":= expiryDate,
        "subdomains":= subdomains
      }
      (enforce-active-registration expiryDate)
      (enforce (= false (contains subdomain subdomains)) "Subdomain already exists")

      (let
        (
          (subfqn (format "{}.{}" [subdomain name]))
        )

        (with-capability (ACCOUNT_GUARD owner)
        (with-capability (NAME_UPSERT subfqn)
        (with-capability (MAPPING)

          (coin.transfer owner VAULT_ACCOUNT SUBDOMAIN_PRICE)

          (update names-table name {
            "subdomains": (+ [subfqn] subdomains)
          })

          ; Set mappings
          (set-mappings subfqn name address)
      ))))
    )
  )

  (defun remove-subdomain (name:string subdomain:string)
    (with-read names-table name
      {
        "owner":= owner,
        "expiryDate":= expiryDate,
        "subdomains":= subdomains
      }
      (enforce-active-registration expiryDate)
      (enforce (contains subdomain subdomains) "Subdomain doesn't exist")

      (with-capability (ACCOUNT_GUARD owner)
      (with-capability (NAME_UPSERT subdomain)
      (with-capability (MAPPING)

        (update names-table name {
          "subdomains": (filter (!= subdomain) subdomains)
        })

        ; Clear mappings
        (remove-mappings subdomain)
      )))
    )
  )

  (defun update-address (address:string name:string)
    (with-read name-map-table name
      {
        "top-level-name":= toplevelname
      }

      (with-read names-table toplevelname
        {
          "owner":= owner,
          "expiryDate":= expiryDate
        }

        (with-capability (ACCOUNT_GUARD owner)
        (with-capability (MAPPING)
          (enforce-active-registration expiryDate)
          (enforce-address-is-valid address)
          (enforce-address-not-in-use address)

          (coin.transfer owner VAULT_ACCOUNT UPDATE_PRICE)

          ; Remove existing mappings and set new mappings
          (remove-mappings name)
          (set-mappings name toplevelname address)
        ))
      ))
  )

  (defun renew (name:string nrDays:integer)
    (enforce-name-is-valid (strip-domain name))
    (enforce-days-is-valid nrDays)
    (with-read names-table name
      {
        "owner":= owner,
        "expiryDate":= expiryDate
      }

      (enforce (<= (curr-time) (add-time expiryDate (days EXPIRATION_GRACE_PERIOD))) "Grace period expired, unable to renew")

      (with-capability (ACCOUNT_GUARD owner)
      (with-capability (NAME_UPSERT name)
        (coin.transfer owner VAULT_ACCOUNT (get-price nrDays))

        (update names-table name {
          "lastPrice": (get-price nrDays),
          "expiryDate": (add-time expiryDate (days nrDays))
        })
      )))
  )

  (defun put-up-for-sale(name:string price:decimal)
    (with-read names-table name
      {
        "owner":= owner,
        "expiryDate":= expiryDate
      }

      (with-capability (ACCOUNT_GUARD owner)
      (with-capability (SALE_STATUS_UPDATED name)
        (enforce-active-registration expiryDate)
        (enforce (> price 0.0) "Price must be greather than 0")

        (write sales-table name {
          "price": price,
          "sellable": true
        })
      ))
    )
  )

  (defun remove-from-sale(name:string)
    (with-read names-table name
      {
        "owner":= owner,
        "expiryDate":= expiryDate
      }

      (with-capability (ACCOUNT_GUARD owner)
      (with-capability (SALE_STATUS_UPDATED name)
        (enforce-active-registration expiryDate)

        (update sales-table name {
          "sellable": false
        })
      ))
    )
  )

  (defun buy-name(name:string newOwner:string newAddress:string)
    (with-read sales-table name
      {
        "price":= price,
        "sellable":= sellable
      }
      (enforce sellable "Name not for sale")
      (enforce-address-is-valid newAddress)
      (enforce-address-not-in-use newAddress)

      (with-capability (ACCOUNT_GUARD newOwner)
        (with-read names-table name
          {
            "owner":= owner,
            "expiryDate":= expiryDate,
            "subdomains":= subdomains
          }
          (enforce-active-registration expiryDate)

          (with-capability (ITEM_SOLD name owner newOwner price)
          (with-capability (MAPPING)
            (let*
              (
                (feeAmount (floor (* (/ price 100) SELL_FEE_PERCENTAGE) (coin.precision)))
              )

              (coin.transfer newOwner owner (- price feeAmount))
              (coin.transfer newOwner VAULT_ACCOUNT feeAmount)
            )

            (update sales-table name {
              "sellable": false
            })

            ; Remove mappings for existing subdomains
            (map (remove-mappings) subdomains)

            ; Add mapping for new address
            (set-mappings name name newAddress)

            (update names-table name {
              "owner": newOwner,
              "lastPrice": price,
              "subdomains": []
            })))
        )
      )
    )
  )

  (defun get-name-info (name:string)
    (with-default-read names-table name {
      "owner": "",
      "lastPrice": 0.0,
      "expiryDate": 0,
      "subdomains": []
    }
    {
      "owner":= owner,
      "lastPrice":= lastPrice,
      "expiryDate":= expiryDate,
      "subdomains":= subdomains
    }

    (if (= owner "") false { "expiryDate": expiryDate, "lastPrice": lastPrice, "owner": owner, "subdomains": subdomains })
    )
  )

  (defun get-sale-state (name:string)
    (with-default-read sales-table name
      {
        "sellable": false,
        "price": 0.0
      }
      {
        "sellable":= sellable,
        "price":= price
      }
      { "sellable": sellable, "price": price }
    )
  )

  (defun get-base-info ()
    {
      "oneYearPrice": BASE_ONEYEAR_PRICE,
      "twoYearPrice": BASE_TWOYEAR_PRICE,
      "subdomainPrice": SUBDOMAIN_PRICE,
      "updatePrice": UPDATE_PRICE,
      "sellFeePercentage": SELL_FEE_PERCENTAGE,
      "expirationGracePeriod": EXPIRATION_GRACE_PERIOD,
      "vaultAccount": VAULT_ACCOUNT
    }
  )

  ; --------------------------------------------------------------------------
  ; Resolver Functions

  (defun get-address (name: string)
    (with-read name-map-table name
      {
        "address":= address,
        "top-level-name":= toplevelname
      }
      (with-read names-table toplevelname
      {
        "expiryDate":= expiryDate
      }
      (enforce-active-registration expiryDate)
      address
    )
    )
  )

  (defun get-name (address: string)
    (with-read address-map-table address
      {
      "name":= name,
      "top-level-name":= toplevelname
      }
      (with-read names-table toplevelname
        {
          "expiryDate":= expiryDate
        }
        (enforce-active-registration expiryDate)
        name
      )
    )
  )

  ; --------------------------------------------------------------------------
  ; Reserved names

  (defun reserve-name (name:string)
    (with-capability (GOVERNANCE)
      (enforce-name-is-valid (strip-domain name))

      (write names-table name {
        "owner": VAULT_ACCOUNT,
        "lastPrice": 0.0,
        "expiryDate": (add-time (curr-time) (days 365)),
        "subdomains": []
      })
    )
  )

  (defun transfer-reserved-name (name:string recipient:string)
    (with-capability (GOVERNANCE)
    (with-capability (NAME_UPSERT name)
    (with-capability (MAPPING)
      (update names-table name {
        "owner": recipient,
        "lastPrice": BASE_ONEYEAR_PRICE
      })

      (set-mappings name name recipient)
    )))
  )

  (defun trigger-events (name:string)
    (with-capability (GOVERNANCE)
    (with-capability (NAME_UPSERT name)
    (with-capability (SALE_STATUS_UPDATED name)
    true
    )))
  )
)


