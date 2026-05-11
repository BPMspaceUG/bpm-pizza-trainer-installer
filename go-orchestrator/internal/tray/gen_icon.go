//go:build ignore

package main

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/png"
	"os"
)

func main() {
	img := image.NewRGBA(image.Rect(0, 0, 16, 16))
	blue := color.RGBA{R: 74, G: 144, B: 226, A: 255}
	for y := 0; y < 16; y++ {
		for x := 0; x < 16; x++ {
			img.Set(x, y, blue)
		}
	}

	var pngBuf bytes.Buffer
	if err := png.Encode(&pngBuf, img); err != nil {
		panic(err)
	}
	pngBytes := pngBuf.Bytes()

	var ico bytes.Buffer
	binary.Write(&ico, binary.LittleEndian, uint16(0))
	binary.Write(&ico, binary.LittleEndian, uint16(1))
	binary.Write(&ico, binary.LittleEndian, uint16(1))

	ico.WriteByte(16)
	ico.WriteByte(16)
	ico.WriteByte(0)
	ico.WriteByte(0)
	binary.Write(&ico, binary.LittleEndian, uint16(1))
	binary.Write(&ico, binary.LittleEndian, uint16(32))
	binary.Write(&ico, binary.LittleEndian, uint32(len(pngBytes)))
	binary.Write(&ico, binary.LittleEndian, uint32(22))

	ico.Write(pngBytes)

	if err := os.WriteFile("icon.ico", ico.Bytes(), 0644); err != nil {
		panic(err)
	}
}
