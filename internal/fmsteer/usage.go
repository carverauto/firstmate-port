package fmsteer

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
)

// UsageRun shows per-account token usage and remaining allowance from the
// portal ledger. No quota math lives here.
func UsageRun(args []string) {
	fs := flag.NewFlagSet("usage", flag.ExitOnError)
	instance := fs.String("instance", Env("FIRSTMATE_INSTANCE", ""), "API base URL")
	asJSON := fs.Bool("json", false, "print the full usage response as JSON")
	_ = parseInterspersed(fs, args)

	c := MustCreds(*instance)
	if *asJSON {
		// Pass the portal's ledger JSON through untouched: decoding into a
		// narrower struct would silently drop fields the portal reports.
		var ledger json.RawMessage
		if err := GetJSON(c.Instance+"/api/usage", c.Token, &ledger); err != nil {
			log.Fatal(err)
		}
		printJSONValue(ledger)
		return
	}
	var out UsageResponse
	if err := GetJSON(c.Instance+"/api/usage", c.Token, &out); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%-12s %-20s %12s %12s %12s %-6s %8s\n", "provider", "label", "allowance", "used", "remaining", "status", "runway")
	for _, a := range out.Data {
		fmt.Printf("%-12s %-20s %12s %12s %12s %-6s %8s\n",
			a.Provider, a.Label, numOrDash(a.Allowance), numOrDash(a.Used),
			numOrDash(a.Remaining), a.Status, runwayOrDash(a.RunwayDays))
	}
}

// UsageAccount is one row of the portal ledger.
type UsageAccount struct {
	Provider   string   `json:"provider"`
	Label      string   `json:"label"`
	Unit       string   `json:"unit"`
	Allowance  *float64 `json:"allowance"`
	Used       *float64 `json:"used"`
	Remaining  *float64 `json:"remaining"`
	Status     string   `json:"status"`
	RunwayDays *float64 `json:"runway_days"`
	Window     string   `json:"window"`
}

// UsageResponse is the body of GET /api/usage.
type UsageResponse struct {
	Tenant string         `json:"tenant"`
	Data   []UsageAccount `json:"data"`
}

func numOrDash(f *float64) string {
	if f == nil {
		return "-"
	}
	return fmt.Sprintf("%.2f", *f)
}

func runwayOrDash(f *float64) string {
	if f == nil {
		return "-"
	}
	return fmt.Sprintf("%.1fd", *f)
}
