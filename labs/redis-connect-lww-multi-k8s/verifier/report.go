package main

type Report struct {
	LWW     LWWResult  `json:"lww"`
	Verdict LWWVerdict `json:"verdict"`
}
