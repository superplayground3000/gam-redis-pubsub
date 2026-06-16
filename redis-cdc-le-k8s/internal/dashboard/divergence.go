// $LAB/dashboard/divergence.go
package dashboard

// Divergence summarizes central-vs-region disagreement: the visible no-LWW
// stale-overwrite / delete-resurrection cost.
type Divergence struct {
	CentralCount int      `json:"central_count"`
	RegionCount  int      `json:"region_count"`
	OnlyCentral  int      `json:"only_central"` // intent present, mirror missing
	OnlyRegion   int      `json:"only_region"`  // resurrected / orphan in mirror
	Differing    int      `json:"differing"`    // both present, bodies differ
	Divergent    int      `json:"divergent"`    // sum of the three
	Samples      []string `json:"samples"`      // up to 20 divergent keys
}

func computeDivergence(central, region map[string]string) Divergence {
	d := Divergence{CentralCount: len(central), RegionCount: len(region)}
	for k, cv := range central {
		rv, ok := region[k]
		switch {
		case !ok:
			d.OnlyCentral++
			d.addSample(k)
		case rv != cv:
			d.Differing++
			d.addSample(k)
		}
	}
	for k := range region {
		if _, ok := central[k]; !ok {
			d.OnlyRegion++
			d.addSample(k)
		}
	}
	d.Divergent = d.OnlyCentral + d.OnlyRegion + d.Differing
	return d
}

func (d *Divergence) addSample(k string) {
	if len(d.Samples) < 20 {
		d.Samples = append(d.Samples, k)
	}
}
