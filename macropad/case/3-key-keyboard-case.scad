// ============================================
// 3-Key Bluetooth Macro Pad Case
// For: nice!nano v2 + Kailh Choc v1 + LiPo
// ============================================
// --- Rendering quality ---
$fn = 40;
// --- Key layout ---
num_keys        = 3;
switch_cutout   = 13.8;   // Choc v1 plate cutout
switch_spacing  = 19.0;   // center-to-center (Choc standard)
keycap_width    = 17.5;   // MBK keycap footprint
keycap_clearance = 0.5;
// --- Case dimensions (auto-calculated) ---
case_padding_x  = 8;      // wall thickness on sides
case_padding_y  = 8;      // wall thickness front/back
case_width      = (num_keys * switch_spacing) + (2 * case_padding_x);
case_depth      = switch_spacing + (2 * case_padding_y);
case_corner_r   = 4;
// --- Heights ---
top_plate_h     = 1.6;    // plate thickness around switch cutouts
bottom_wall_h   = 1.2;    // bottom shell floor thickness
cavity_depth    = 9.0;    // internal space for PCB + battery + wires
total_height    = bottom_wall_h + cavity_depth + top_plate_h;
// --- nice!nano pocket ---
nano_w          = 18.5;   // width + clearance
nano_l          = 34.5;   // length + clearance
nano_h          = 4.0;    // board + components height
nano_offset_x   = case_width/2 - nano_w/2;
nano_offset_y   = case_depth - case_padding_y - nano_l - 1;
// --- Battery pocket ---
batt_w          = 13;
batt_l          = 29;
batt_h          = 4.5;    // battery + wire clearance
batt_offset_x   = nano_offset_x - batt_w - 2;
batt_offset_y   = nano_offset_y + (nano_l - batt_l)/2;
// --- USB-C port ---
usbc_w          = 10;
usbc_h          = 3.6;
// --- Reset button hole (opposite wall from USB-C side) ---
reset_hole_d    = 4;      // diameter — adjust if needed
// --- Mounting ---
screw_d         = 2.2;    // M2 screw hole diameter
standoff_d      = 4.5;
standoff_h      = cavity_depth - 0.4;
// ============================================
// MODULES
// ============================================
module rounded_box(w, d, h, r) {
    hull() {
        for (x = [r, w-r], y = [r, d-r])
            translate([x, y, 0])
                cylinder(r=r, h=h);
    }
}
module switch_cutout() {
    // Square cutout for Choc v1 switch
    translate([0, 0, -0.1])
        cube([switch_cutout, switch_cutout, top_plate_h + 0.2]);
    
    // Small side clips for snap-in retention (Choc spec)
    for (side = [0, 1]) {
        mirror([side, 0, 0])
        translate([-0.8, switch_cutout/2 - 2, -0.1])
            cube([0.9, 4, top_plate_h + 0.2]);
    }
}
module top_plate() {
    difference() {
        // Main plate
        rounded_box(case_width, case_depth, top_plate_h, case_corner_r);
        
        // Switch cutouts
        for (i = [0 : num_keys-1]) {
            key_cx = case_padding_x + (i * switch_spacing) + switch_spacing/2;
            key_cy = case_depth / 2;
            translate([key_cx - switch_cutout/2,
                       key_cy - switch_cutout/2, 0])
                switch_cutout();
        }
        
        // Screw holes (4 corners)
        for (pos = screw_positions())
            translate([pos[0], pos[1], -0.1])
                cylinder(d=screw_d, h=top_plate_h + 0.2);
    }
}
module bottom_shell() {
    difference() {
        // Outer shell
        rounded_box(case_width, case_depth, 
                     bottom_wall_h + cavity_depth, case_corner_r);
        
        // Main cavity
        translate([1.5, 1.5, bottom_wall_h])
            rounded_box(case_width - 3, case_depth - 3,
                        cavity_depth + 0.1, case_corner_r - 1);
        
        // nice!nano pocket (recessed)
        translate([nano_offset_x, nano_offset_y+9.5, bottom_wall_h - 0.1])
            cube([nano_w, nano_l-3, nano_h + 0.1]);
        
        // Battery pocket
        translate([batt_offset_x, batt_offset_y+7.5, bottom_wall_h - 0.1])
            cube([batt_w, batt_l-3, batt_h + 0.1]);
        
        // USB-C port opening (back wall)
        translate([case_width/2 - usbc_w/2,
                   case_depth - 2,
                   bottom_wall_h + 1])
            cube([usbc_w, 4, usbc_h]);
        
        // Reset button hole (right wall, opposite side from where switch was)
        translate([case_width - 2,
                   case_depth/2,
                   bottom_wall_h + cavity_depth/2])
            rotate([0, 90, 0])
                cylinder(d=reset_hole_d, h=4);
        
        // Screw holes
        for (pos = screw_positions())
            translate([pos[0], pos[1], -0.1])
                cylinder(d=screw_d, h=bottom_wall_h + 0.2);
    }
    
    // Screw standoffs
    for (pos = screw_positions()) {
        translate([pos[0], pos[1], bottom_wall_h])
            difference() {
                cylinder(d=standoff_d, h=standoff_h);
                translate([0, 0, -0.1])
                    cylinder(d=screw_d, h=standoff_h + 0.2);
            }
    }
}
function screw_positions() = [
    [case_corner_r + 1.5, case_corner_r + 1.5],
    [case_width - case_corner_r - 1.5, case_corner_r + 1.5],
    [case_corner_r + 1.5, case_depth - case_corner_r - 1.5],
    [case_width - case_corner_r - 1.5, case_depth - case_corner_r - 1.5]
];
// ============================================
// ASSEMBLY VIEW
// ============================================
// Toggle which part to render for STL export:
//   part = "assembly" -> preview both together (exploded)
//   part = "top"      -> export top plate STL
//   part = "bottom"   -> export bottom shell STL
part = "assembly"; // <-- change this for export
if (part == "assembly") {
    // Bottom shell
    color("#d0d0d0") bottom_shell();
    
    // Top plate (exploded upward for visibility)
    color("#e8e8e8")
        translate([0, 0, bottom_wall_h + cavity_depth + 3])
            top_plate();
    
    // Ghost outlines for components
    // nice!nano
    color("#1D9E75", 0.3)
        translate([nano_offset_x, nano_offset_y+9.5, bottom_wall_h])
            cube([nano_w, nano_l-3, 2]);
    // Battery
    color("#EF9F27", 0.3)
        translate([batt_offset_x, batt_offset_y+7.5, bottom_wall_h])
            cube([batt_w, batt_l-3, batt_h]);
} else if (part == "top") {
    top_plate();
    
} else if (part == "bottom") {
    bottom_shell();
}
// ============================================
// DIMENSIONS (for reference)
// ============================================
// Case outer:  ~65 x 43 x 11.8 mm
// Switch spacing: 19mm center-to-center
// Print: top plate face-down, 0.12mm layers
// Hardware: 4x M2x6 screws
// Reset hole: right wall, parameterized diameter
// ============================================