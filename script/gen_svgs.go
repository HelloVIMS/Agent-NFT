// +build ignore

package main

import (
	"fmt"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
)

const viewBox = "0 0 500 500"

func main() {
	outDir := "test-assets/svgs"
	os.MkdirAll(outDir, 0755)

	generators := []func() string{
		genNebula,
		genCircuit,
		genCrystal,
		genOracle,
		genFlux,
		genPrism,
		genNexus,
		genVertex,
		genTide,
		genSingularity,
	}

	names := []string{
		"Nebula", "Circuit", "Crystal", "Oracle", "Flux",
		"Prism", "Nexus", "Vertex", "Tide", "Singularity",
	}

	for i, gen := range generators {
		svg := gen()
		name := names[i]
		path := filepath.Join(outDir, fmt.Sprintf("agent_%02d_%s.svg", i, strings.ToLower(name)))
		os.WriteFile(path, []byte(svg), 0644)
		fmt.Printf("%s: %d bytes\n", name, len(svg))
	}
}

func genNebula() string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="500" height="500">`, viewBox))
	b.WriteString(`<defs><radialGradient id="bg" cx="50%" cy="50%" r="70%"><stop offset="0%" stop-color="#0a0a1a"/><stop offset="50%" stop-color="#1a0a2e"/><stop offset="100%" stop-color="#000000"/></radialGradient><filter id="glow"><feGaussianBlur stdDeviation="3" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>`)
	b.WriteString(`<rect width="500" height="500" fill="url(#bg)"/>`)

	rng := rand.New(rand.NewSource(42))
	colors := []string{"#ff3366", "#33ffcc", "#cc33ff", "#ffcc33", "#33ccff", "#ff6633"}
	for i := 0; i < 300; i++ {
		cx := rng.Float64() * 500
		cy := rng.Float64() * 500
		r := 2 + rng.Float64()*40
		op := 0.05 + rng.Float64()*0.25
		c := colors[rng.Intn(len(colors))]
		b.WriteString(fmt.Sprintf(`<circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s" opacity="%.3f" filter="url(#glow)"/>`, cx, cy, r, c, op))
	}
	for i := 0; i < 150; i++ {
		x1 := rng.Float64() * 500
		y1 := rng.Float64() * 500
		x2 := x1 + (rng.Float64()-0.5)*100
		y2 := y1 + (rng.Float64()-0.5)*100
		c := colors[rng.Intn(len(colors))]
		b.WriteString(fmt.Sprintf(`<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="%s" stroke-width="0.5" opacity="0.3"/>`, x1, y1, x2, y2, c))
	}
	b.WriteString(`</svg>`)
	return b.String()
}

func genCircuit() string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="500" height="500">`, viewBox))
	b.WriteString(`<rect width="500" height="500" fill="#0a0f0a"/><g stroke="#00ff44" stroke-width="1" fill="none" opacity="0.6">`)

	grid := 25
	for x := 0; x <= 500; x += grid {
		for y := 0; y <= 500; y += grid {
			if rand.Float64() < 0.7 {
				continue
			}
			dir := rand.Intn(4)
			switch dir {
			case 0:
				b.WriteString(fmt.Sprintf(`<path d="M%d,%d L%d,%d"/>`, x, y, x+grid, y))
			case 1:
				b.WriteString(fmt.Sprintf(`<path d="M%d,%d L%d,%d"/>`, x, y, x, y+grid))
			case 2:
				b.WriteString(fmt.Sprintf(`<path d="M%d,%d L%d,%d L%d,%d"/>`, x, y, x+grid, y, x+grid, y+grid))
			case 3:
				b.WriteString(fmt.Sprintf(`<path d="M%d,%d L%d,%d L%d,%d"/>`, x, y, x, y+grid, x+grid, y+grid))
			}
			if rand.Float64() < 0.3 {
				b.WriteString(fmt.Sprintf(`<circle cx="%d" cy="%d" r="3" fill="#00ff44"/>`, x, y))
			}
		}
	}
	b.WriteString(`</g>`)
	b.WriteString(`<g fill="#00ff44" opacity="0.9">`)
	for i := 0; i < 8; i++ {
		sx := 20 + rand.Intn(460)
		sy := 20 + rand.Intn(460)
		b.WriteString(fmt.Sprintf(`<rect x="%d" y="%d" width="12" height="12" rx="2"/>`, sx, sy))
		b.WriteString(fmt.Sprintf(`<text x="%d" y="%d" font-family="monospace" font-size="8" fill="#00ff44">%02x</text>`, sx+16, sy+9, rand.Intn(256)))
	}
	b.WriteString(`</g></svg>`)
	return b.String()
}

func genCrystal() string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="500" height="500">`, viewBox))
	b.WriteString(`<defs><linearGradient id="c1" x1="0%" y1="0%" x2="100%" y2="100%"><stop offset="0%" stop-color="#e0f7fa"/><stop offset="100%" stop-color="#006064"/></linearGradient><linearGradient id="c2" x1="0%" y1="100%" x2="100%" y2="0%"><stop offset="0%" stop-color="#b2ebf2"/><stop offset="100%" stop-color="#00838f"/></linearGradient><linearGradient id="c3" x1="50%" y1="0%" x2="50%" y2="100%"><stop offset="0%" stop-color="#80deea"/><stop offset="100%" stop-color="#0097a7"/></linearGradient></defs>`)
	b.WriteString(`<rect width="500" height="500" fill="#001518"/>`)

	centers := [][2]float64{{250, 250}, {120, 120}, {380, 120}, {120, 380}, {380, 380}}
	grads := []string{"url(#c1)", "url(#c2)", "url(#c3)", "url(#c1)", "url(#c2)"}
	for ci, center := range centers {
		cx, cy := center[0], center[1]
		for i := 0; i < 12; i++ {
			angle := float64(i) * 2 * math.Pi / 12
			points := []string{}
			for j := 0; j < 3; j++ {
				a := angle + float64(j)*2*math.Pi/3
				x := cx + math.Cos(a)*60
				y := cy + math.Sin(a)*60
				points = append(points, fmt.Sprintf("%.1f,%.1f", x, y))
			}
			b.WriteString(fmt.Sprintf(`<polygon points="%s" fill="%s" opacity="0.4" stroke="rgba(255,255,255,0.3)" stroke-width="0.5"/>`, strings.Join(points, " "), grads[ci]))
		}
	}
	b.WriteString(`</svg>`)
	return b.String()
}

func genOracle() string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="500" height="500">`, viewBox))
	b.WriteString(`<defs><radialGradient id="obg" cx="50%" cy="50%" r="50%"><stop offset="0%" stop-color="#1a0033"/><stop offset="100%" stop-color="#000000"/></radialGradient><filter id="oglow"><feGaussianBlur stdDeviation="2"/></filter></defs>`)
	b.WriteString(`<rect width="500" height="500" fill="url(#obg)"/>`)

	for r := 20; r <= 240; r += 15 {
		b.WriteString(fmt.Sprintf(`<circle cx="250" cy="250" r="%d" fill="none" stroke="#aa33ff" stroke-width="0.5" opacity="%.2f"/>`, r, 0.1+float64(r)/500))
	}
	for i := 0; i < 360; i += 6 {
		angle := float64(i) * math.Pi / 180
		x2 := 250 + math.Cos(angle)*240
		y2 := 250 + math.Sin(angle)*240
		b.WriteString(fmt.Sprintf(`<line x1="250" y1="250" x2="%.1f" y2="%.1f" stroke="#aa33ff" stroke-width="0.3" opacity="0.2"/>`, x2, y2))
	}
	b.WriteString(`<circle cx="250" cy="250" r="80" fill="none" stroke="#ff00ff" stroke-width="2" opacity="0.6" filter="url(#oglow)"/>`)
	b.WriteString(`<circle cx="250" cy="250" r="40" fill="none" stroke="#00ffff" stroke-width="1.5" opacity="0.8"/>`)
	b.WriteString(`<text x="250" y="254" text-anchor="middle" font-family="monospace" font-size="10" fill="#00ffff" opacity="0.7">OMNISCIENT</text>`)
	b.WriteString(`</svg>`)
	return b.String()
}

func genFlux() string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="500" height="500">`, viewBox))
	b.WriteString(`<rect width="500" height="500" fill="#050510"/>`)

	colors := []string{"#ff0055", "#00ffaa", "#5500ff", "#ffaa00", "#00aaff"}
	for n := 0; n < 4; n++ {
		c := colors[n]
		b.WriteString(fmt.Sprintf(`<g stroke="%s" stroke-width="0.8" fill="none" opacity="0.5">`, c))
		for i := 0; i < 40; i++ {
			x, y := float64(50+rand.Intn(400)), float64(50+rand.Intn(400))
			path := fmt.Sprintf(`M%.1f,%.1f `, x, y)
			for j := 0; j < 6; j++ {
				x += (rand.Float64() - 0.5) * 60
				y += (rand.Float64() - 0.5) * 60
				path += fmt.Sprintf(`L%.1f,%.1f `, x, y)
			}
			b.WriteString(fmt.Sprintf(`<path d="%s"/>`, path))
		}
		b.WriteString(`</g>`)
	}
	b.WriteString(`</svg>`)
	return b.String()
}

func genPrism() string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="500" height="500">`, viewBox))
	b.WriteString(`<rect width="500" height="500" fill="#111"/>`)

	cx, cy := 250.0, 250.0
	segments := 36
	for ring := 1; ring <= 8; ring++ {
		r := float64(ring) * 28
		for i := 0; i < segments; i++ {
			a1 := float64(i) * 2 * math.Pi / float64(segments)
			a2 := float64(i+1) * 2 * math.Pi / float64(segments)
			x1 := cx + math.Cos(a1)*r
			y1 := cy + math.Sin(a1)*r
			x2 := cx + math.Cos(a2)*r
			y2 := cy + math.Sin(a2)*r
			hue := (float64(i)*10 + float64(ring)*20) / 360
			// Simple hue-to-rgb approximation for SVG
			c := fmt.Sprintf("hsl(%d,80%%,50%%)", int(hue*360)%360)
			b.WriteString(fmt.Sprintf(`<polygon points="%.1f,%.1f %.1f,%.1f %.1f,%.1f" fill="%s" opacity="0.7"/>`, cx, cy, x1, y1, x2, y2, c))
		}
	}
	b.WriteString(`</svg>`)
	return b.String()
}

func genNexus() string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="500" height="500">`, viewBox))
	b.WriteString(`<rect width="500" height="500" fill="#0a0a0a"/>`)

	// Generate nodes
	numNodes := 80
	nodes := make([][2]float64, numNodes)
	for i := range nodes {
		nodes[i] = [2]float64{rand.Float64() * 500, rand.Float64() * 500}
	}

	b.WriteString(`<g stroke="#444" stroke-width="0.3">`)
	for i := 0; i < numNodes; i++ {
		for j := i + 1; j < numNodes; j++ {
			dx := nodes[i][0] - nodes[j][0]
			dy := nodes[i][1] - nodes[j][1]
			dist := math.Sqrt(dx*dx + dy*dy)
			if dist < 80 {
				op := 1.0 - dist/80
				b.WriteString(fmt.Sprintf(`<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" opacity="%.2f"/>`, nodes[i][0], nodes[i][1], nodes[j][0], nodes[j][1], op*0.5))
			}
		}
	}
	b.WriteString(`</g>`)
	b.WriteString(`<g fill="#fff">`)
	for _, n := range nodes {
		r := 1.0 + rand.Float64()*2.5
		b.WriteString(fmt.Sprintf(`<circle cx="%.1f" cy="%.1f" r="%.1f"/>`, n[0], n[1], r))
	}
	b.WriteString(`</g></svg>`)
	return b.String()
}

func genVertex() string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="500" height="500">`, viewBox))
	b.WriteString(`<rect width="500" height="500" fill="#0d1117"/>`)

	seeds := make([][2]float64, 6)
	for i := range seeds {
		seeds[i] = [2]float64{rand.Float64() * 500, rand.Float64() * 500}
	}

	step := 28
	for x := 0; x < 500; x += step {
		for y := 0; y < 500; y += step {
			minDist := math.MaxFloat64
			for _, s := range seeds {
				d := math.Sqrt(math.Pow(float64(x)-s[0], 2) + math.Pow(float64(y)-s[1], 2))
				if d < minDist {
					minDist = d
				}
			}
			intensity := math.Min(minDist/180, 1.0)
			gray := int(30 + intensity*180)
			b.WriteString(fmt.Sprintf(`<rect x="%d" y="%d" width="%d" height="%d" fill="rgb(%d,%d,%d)" opacity="0.8"/>`, x, y, step+2, step+2, gray, gray+20, gray+40))
		}
	}
	b.WriteString(`</svg>`)
	return b.String()
}

func genTide() string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="500" height="500">`, viewBox))
	b.WriteString(`<rect width="500" height="500" fill="#001122"/>`)

	for y := 0; y < 500; y += 5 {
		path := fmt.Sprintf(`M0,%d `, y)
		for x := 0; x <= 500; x += 16 {
			dy := math.Sin(float64(x)*0.05+float64(y)*0.02)*8 + math.Sin(float64(x)*0.02+float64(y)*0.05)*5
			path += fmt.Sprintf(`L%d,%.1f `, x, float64(y)+dy)
		}
		b.WriteString(fmt.Sprintf(`<path d="%s" stroke="rgba(0,200,255,%.2f)" stroke-width="0.6" fill="none"/>`, path, 0.1+float64(y)/1000))
	}
	b.WriteString(`</svg>`)
	return b.String()
}

func genSingularity() string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" width="500" height="500">`, viewBox))
	b.WriteString(`<defs><radialGradient id="sbg" cx="50%" cy="50%" r="50%"><stop offset="0%" stop-color="#000000"/><stop offset="30%" stop-color="#220011"/><stop offset="60%" stop-color="#110022"/><stop offset="100%" stop-color="#000000"/></radialGradient></defs>`)
	b.WriteString(`<rect width="500" height="500" fill="url(#sbg)"/>`)

	cx, cy := 250.0, 250.0
	for arm := 0; arm < 6; arm++ {
		baseAngle := float64(arm) * math.Pi / 3
		b.WriteString(fmt.Sprintf(`<g stroke="#ff0066" stroke-width="0.5" fill="none" opacity="0.4">`))
		for i := 0; i < 200; i++ {
			t := float64(i) / 10
			angle := baseAngle + t*0.3
			r := t * 12
			x := cx + math.Cos(angle)*r
			y := cy + math.Sin(angle)*r
			if i == 0 {
				b.WriteString(fmt.Sprintf(`<path d="M%.1f,%.1f `, x, y))
			} else {
				b.WriteString(fmt.Sprintf(`L%.1f,%.1f `, x, y))
			}
		}
		b.WriteString(`"/>`)
		b.WriteString(`</g>`)
	}
	for r := 5; r <= 100; r += 10 {
		b.WriteString(fmt.Sprintf(`<circle cx="250" cy="250" r="%d" fill="none" stroke="#ff0066" stroke-width="0.3" opacity="0.2"/>`, r))
	}
	b.WriteString(`<circle cx="250" cy="250" r="8" fill="#ffffff" opacity="0.9"/>`)
	b.WriteString(`<circle cx="250" cy="250" r="15" fill="none" stroke="#ffffff" stroke-width="0.5" opacity="0.4"/>`)
	b.WriteString(`</svg>`)
	return b.String()
}
