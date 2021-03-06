//
//  AC_Controller.m
//  Acid.Cam.2
//
//  Created by Jared Bruni on 6/3/13.
//  Copyright (c) 2017 Jared Bruni. All rights reserved.
//
#import "AC_Controller.h"
#import"videocapture.h"
#import"ac.h"
#include<string>
#include<dlfcn.h>
#include<unistd.h>
#include<dirent.h>
#include<time.h>

NSTextView *logView;
NSTextField *frame_count;
NSMutableArray *custom_array;
bool isPaused = false;
NSSlider *frame_slider;
NSMenuItem *stop_prog_i;
AC_Controller *controller;
pixel pix;
drawn d;
bool plugin_loaded = false;
void *library = NULL;
std::ostringstream ftext;
std::ostringstream stream;
cv::Mat blend_image;
bool blend_set = false;

extern int program_main(std::string input_file, bool noRecord, std::string outputFileName, int capture_width, int capture_height, int capture_device, int frame_count, float pass2_alpha, std::string file_path);

void flushToLog(std::ostringstream &sout) {
    NSTextView *sv = logView;
    NSString *value = [[sv textStorage] string];
    NSString *newValue = [[NSString alloc] initWithFormat: @"%@%s", value, sout.str().c_str()];
    [sv setString: newValue];
    [sv scrollRangeToVisible:NSMakeRange([[sv string] length], 0)];
    [newValue release];
    sout.str("");
}

void setFrameLabel(std::ostringstream &text) {
    NSString *str = [NSString stringWithUTF8String: text.str().c_str()];
    [frame_count setStringValue: str];
    text.str("");
}

void setEnabledProg() {
    [stop_prog_i setEnabled: NO];
}

@implementation AC_Controller

- (void) stopCV_prog {
    [startProg setEnabled: YES];
    programRunning = false;
}


- (IBAction) quitProgram: (id) sender {
    if(programRunning == true)
        breakProgram = true;
    else {
        [NSApp terminate:nil];
    }
}

- (void) dealloc {
    [custom_array release];
    [self closePlugin];
    [super dealloc];
}

- (void) awakeFromNib {
    controller = self;
    [video_file setEnabled: NO];
    [resolution setEnabled: NO];
    [device_index setEnabled: NO];
    [record_audio setEnabled: NO];
    logView = t_view;
    frame_count = framecount;
    [window1 setLevel: NSStatusWindowLevel];
    [window2 setLevel: NSStatusWindowLevel];
    [custom_window setLevel: NSStatusWindowLevel];
    [alpha_window setLevel: NSStatusWindowLevel];
    for(unsigned int i = 0; i < ac::draw_max-3; ++i){
        NSString *s = [NSString stringWithUTF8String: ac::draw_strings[i].c_str()];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:s action:NULL keyEquivalent:@""];
        [[current_filter menu] addItem:item];
        [item release];
        if(ac::draw_strings[i] != "Custom")
            [filter_combo addItemWithObjectValue:s];
    }
    custom_array = [[NSMutableArray alloc] init];
    [table_view setDelegate:self];
    [table_view setDataSource:self];
    [menuPaused setEnabled: NO];
    stop_prog_i = stop_prog;
    frame_slider = goto_f;
    ftext.setf(std::ios::fixed, std::ios::floatfield);
    ftext.precision(2);
    srand((unsigned int)time(0));
    pauseStepTrue = false;
}

- (IBAction) changeFilter: (id) sender {
    NSInteger current = [current_filter indexOfSelectedItem];
    ac::draw_offset = (int)current;
    std::ostringstream strout;
    strout << "Filter set to: " << ac::draw_strings[ac::draw_offset] << "\n";
    flushToLog(strout);
    if(ac::draw_strings[ac::draw_offset] == "Custom") {
        [negate_checked setIntegerValue: NSOffState];
        [custom_window orderFront:self];
    }
    if(ac::draw_strings[ac::draw_offset] == "Alpha Flame Filters") {
        [alpha_window orderFront:self];
    }
    if(ac::draw_strings[ac::draw_offset] == "Plugin") {
        [plugin_window orderFront:self];
    }
    if((ac::draw_strings[ac::draw_offset] == "Blend with Image") || (ac::draw_strings[ac::draw_offset] == "Blend with Image #2") || (ac::draw_strings[ac::draw_offset] == "Blend with Image #3") || (ac::draw_strings[ac::draw_offset] == "Blend with Image #4")) {
        [image_select orderFront: self];
    }
}

- (IBAction) downloadNewestVersion: (id) sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://lostsidedead.com/blog/?index=212"]];
}

- (IBAction) stopProgram: (id) sender {
    stopProgram = true;
    [menuPaused setEnabled: NO];
    stopCV();
}

- (IBAction) selectPlugin: (id) sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:NO];
    [panel setCanChooseDirectories:YES];
    if([panel runModal]) {
        NSString *file_type = [[panel URL] path];
        [plugin_dir removeAllItems];
        [plugin_name setStringValue: file_type];
        [self loadDir:[file_type UTF8String]];
    }
}

- (IBAction) setPlugin: (id) sender {
    [self closePlugin];
    NSString *file_type = [NSString stringWithFormat: @"%@/%@", [plugin_name stringValue], [plugin_dir objectValueOfSelectedItem]];
    pix = [self loadPlugin: file_type];
    if(pix == NULL)
        plugin_loaded = false;
    else
        plugin_loaded = true;
}

- (void) loadDir: (std::string) str {
    DIR *dir = opendir(str.c_str());
    if (dir == NULL)
    {
        std::cerr << "Error could not open directory.\n";
        return;
    }
    dirent *e;
    while ((e = readdir(dir)))
    {
        if (e->d_type == DT_REG)
        {
            std::string file = e->d_name;
            if (file.find(".dylib") != -1)
            {
                
                NSString *s = [NSString stringWithUTF8String: e->d_name];
                [plugin_dir addItemWithObjectValue: s];
                
            }
        }
    }
    closedir(dir);
}

- (pixel) loadPlugin: (NSString *)str {
    library = dlopen([str UTF8String], RTLD_LAZY);
    if(library == NULL) {
        std::cerr << "Error could not open: " << [str UTF8String] << "\n";
        NSRunAlertPanel(@"Error Occoured Loading Plugin", @"Exiting...", @"Ok", nil, nil);
        exit(1);
    }
    void *addr;
    // load the plugin function to process pixels
    addr = dlsym(library, "pixel");
    pixel pix;
    pix = reinterpret_cast<pixel>(addr);
    const char *error;
    error = dlerror();
    if(error) {
        std::cerr << "Could not load pixel: " << error << "\n";
        NSRunAlertPanel(@"Could not load Plugin", @"Error loading plugin", @"Ok", nil,nil);
        return NULL;
    }
    addr = dlsym(library,"drawn");
    d = reinterpret_cast<drawn>(addr);
    error = dlerror();
    if(error) {
        std::cerr << "Could not load pixel: " << error << "\n";
        NSRunAlertPanel(@"Could not load Plugin", @"Error loading plugin", @"Ok", nil,nil);
        return NULL;
    }
    return pix;
}

- (void) closePlugin {
    if(library != NULL)
        dlclose(library);
}


-(IBAction) startProgram: (id) sender {
    std::string input_file;
    if([videoFileInput integerValue] != 0) {
        input_file = [[video_file stringValue] UTF8String];
        if(input_file.length() == 0) {
            NSRunAlertPanel(@"No Input file selected\n", @"No Input Selected", @"Ok", nil, nil);
            return;
        }
    }
    NSInteger res = [resolution indexOfSelectedItem];
    int res_x[3] = { 640, 1280, 1920 };
    int res_y[3] = { 480, 720, 1080 };
    bool r, raudio;
    if([record_op integerValue] == 1)
        r = false;
    else
        r = true;
    if([record_audio integerValue] == 1)
        raudio = true;
    else
        raudio = false;
    
    static unsigned int counter = 0;
    std::ostringstream fname_stream;
    std::string filename;
    NSInteger popupType = [output_Type indexOfSelectedItem];
    if(!r) {
        ++counter;
    }
    time_t t = time(0);
    struct tm *m;
    m = localtime(&t);
    std::ostringstream time_stream;
    time_stream << "-" << (m->tm_year + 1900) << "." << (m->tm_mon + 1) << "." << m->tm_mday << "_" << m->tm_hour << "." << m->tm_min << "." << m->tm_sec <<  "_";
    if(popupType == 0)
        fname_stream << time_stream.str() << "AC2.Output." << (counter) << ".mov";
    else
        fname_stream << time_stream.str() << "AC2.Output." << (counter) << ".avi";
    
    filename = fname_stream.str();
    NSArray* paths = NSSearchPathForDirectoriesInDomains( NSMoviesDirectory, NSUserDomainMask, YES );
    std::string add_path = std::string([[paths objectAtIndex: 0] UTF8String])+std::string("/")+[[prefix_input stringValue] UTF8String];
    std::cout << add_path << "\n";
    [startProg setEnabled: NO];
    [window1 orderFront:self];
    [menuPaused setEnabled: YES];
    renderTimer = [NSTimer timerWithTimeInterval:0.001   //a 1ms time interval
                                          target:self
                                        selector:@selector(cvProc:)
                                        userInfo:nil
                                         repeats:YES];
    
    int ret_val = program_main((int)popupType, input_file, r, raudio, filename, res_x[res], res_y[res],(int)[device_index indexOfSelectedItem], 0, 0.75f, add_path);
    if(ret_val != 0) {
        NSRunAlertPanel(@"Failed to initalize camera\n", @"Camera Init Failed\n", @"Ok", nil, nil);
        std::cout << "DeviceIndex: " << (int)[device_index indexOfSelectedItem] << " input file: " << input_file << " filename: " << filename << " res: " << res_x[res] << "x" << res_y[res] << "\n";
        programRunning = false;
    }
}

- (void) cvProc: (id) sender {
    if(breakProgram == true || stopProgram == true) { stopCV(); return; }
    if(isPaused && pauseStepTrue == true) {
        pauseStepTrue = false;
    }
    else if(isPaused) return;
    cv::Mat frame;
    if(capture.read(frame) == false) {
        ++frame_cnt;
        ftext  << "(Frames/Total Frames/Seconds/MB): " << frame_cnt << "/" << total_frames << "/" << (frame_cnt/ac::fps) << "/" << ((file_size/1024)/1024) << " MB";
        if(ac::noRecord == false) {
            writer.write(frame);
            if(file.is_open()) {
                file.seekg(0, std::ios::end);
                file_size = file.tellg();
            }
            float val = frame_cnt;
            float size = total_frames;
            
            if(size != 0)
            ftext << " - " <<(val/size)*100 << "% ";
        }
        setFrameLabel(ftext);
        stopCV();
        return;
    }
    if((ac::draw_strings[ac::draw_offset] == "Blend with Source") || (ac::draw_strings[ac::draw_offset] == "Custom")) {
        ac::orig_frame = frame.clone();
    }
    
    if(ac::draw_strings[ac::draw_offset] != "Custom") {
        if([negate_checked integerValue] == NSOffState) ac::isNegative = false;
        else ac::isNegative = true;
        ac::color_order = (int) [corder indexOfSelectedItem];
    }
    if(disableFilter == false) ac::draw_func[ac::draw_offset](frame);
	++frame_cnt;
    imshow("Acid Cam v2", frame);

    ftext << "(Frames/Total Frames/Seconds/MB): " << frame_cnt << "/" << total_frames << "/" << (frame_cnt/ac::fps) << "/" << ((file_size/1024)/1024) << " MB";
    
    if(ac::noRecord == false) {
        float val = frame_cnt;
        float size = total_frames;
        if(size != 0)
        ftext << " - " << (val/size)*100 << "% ";
    }
    setFrameLabel(ftext);
    if(ac::noRecord == false) {
        writer.write(frame);
        if(file.is_open()) {
            file.seekg(0, std::ios::end);
            file_size = file.tellg();
        }
    }
    if(ac::snapShot == true) {
        static unsigned int index = 0;
        stream.str("");
        time_t t = time(0);
        struct tm *m;
        m = localtime(&t);
        stream << add_path << "-" << (m->tm_year + 1900) << "." << (m->tm_mon + 1) << "." << m->tm_mday << "_" << m->tm_hour << "." << m->tm_min << "." << m->tm_sec <<  "_" << (++index) << ".Acid.Cam.Image." << ac::draw_strings[ac::draw_offset] << ((ac::snapshot_Type == 0) ? ".jpg" : ".png");
        imwrite(stream.str(), frame);
        sout << "Took snapshot: " << stream.str() << "\n";
        ac::snapShot = false;
        // flush to log
        flushToLog(sout);
    }
}

- (IBAction) openWebcamDialog: (id) sender {
    if([startaction indexOfSelectedItem] == 0)
        [window1 orderFront: self];
    else { // load video
        [window2 orderFront: self];
    }
}

- (IBAction) startVideoProgram: (id) sender {}

- (IBAction) selectFile: (id) sender {
    NSOpenPanel *pan = [NSOpenPanel openPanel];
    [pan setAllowsMultipleSelection: NO];
    NSArray *ar = [NSArray arrayWithObjects: @"mov", @"avi", @"mp4", @"mkv",@"m4v", nil];
    [pan setAllowedFileTypes:ar];
    if([pan runModal]) {
        NSString *file_name = [[pan URL] path];
        if(file_name != 0) {
            [video_file setStringValue: file_name];
        }
    }
}

- (IBAction) takeSnopshot: (id) sender {
    ac::snapShot = true;
    ac::snapshot_Type = 0;
}

- (IBAction) takeSnapshotPNG: (id) sender {
    ac::snapShot = true;
    ac::snapshot_Type = 1;
}

- (IBAction) checkChanged: (id) sender {
    if([videoFileInput integerValue] == 0 ) {
        [video_file setEnabled: NO];
        [resolution setEnabled: YES];
        [device_index setEnabled: YES];
        [record_audio setEnabled: YES];
        [selectVideoFile setEnabled: NO];
    }
    else {
        [video_file setEnabled: NO];
        [resolution setEnabled: NO];
        [device_index setEnabled: NO];
        [record_audio setEnabled: NO];
        [selectVideoFile setEnabled: YES];
    }
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
    NSString *str =  [[aTableColumn headerCell] stringValue];
    NSNumber *number = [custom_array objectAtIndex:rowIndex];
    if( [str isEqualTo:@"Filter"] ) {
        int value = (int)[number integerValue];
        NSString *s = [NSString stringWithFormat:@"%s", ac::draw_strings[value].c_str()];
        //        [number release];
        return s;
    }
    else {
        NSString *s = [NSString stringWithFormat: @"%d", (int)[number integerValue]];
        //        [number release];
        return s;
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView {
    return [custom_array count];
}

- (IBAction) addCustomItem: (id) sender {
    NSInteger index = [filter_combo indexOfSelectedItem];
    if(index >= 0) {
        [custom_array addObject: [NSNumber numberWithInt: (int)index]];
        [table_view reloadData];
    }
}
- (IBAction) removeCustomItem: (id) sender {
    NSInteger index = [table_view selectedRow];
    if(index >= 0) {
        [custom_array removeObjectAtIndex:index];
        [table_view reloadData];
    }
}

- (IBAction) moveCustomUp: (id) sender {
    NSInteger index = [table_view selectedRow];
    if(index > 0) {
        NSInteger pos = index-1;
        id obj = [custom_array objectAtIndex:pos];
        id mv = [custom_array objectAtIndex:index];
        [custom_array setObject:obj atIndexedSubscript:index];
        [custom_array setObject:mv atIndexedSubscript: pos];
        [table_view deselectAll:self];
        [table_view reloadData];
    }
}
- (IBAction) moveCustomDown: (id) sender {
    NSInteger index = [table_view selectedRow];
    if(index < [custom_array count]-1) {
        NSInteger pos = index+1;
        id obj = [custom_array objectAtIndex:pos];
        id mv = [custom_array objectAtIndex:index];
        [custom_array setObject:obj atIndexedSubscript:index];
        [custom_array setObject:mv atIndexedSubscript: pos];
        [table_view deselectAll:self];
        [table_view reloadData];
    }
}

- (IBAction) stepPause: (id) sender {
    pauseStepTrue = true;
}

- (IBAction) selectFileForPrefix: (id) sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    if([panel runModal]) {
        [prefix_input setStringValue:[[panel URL] path]];
    }
}

- (IBAction) changeOrder: (id) sender {
    ac::color_order = (int) [corder indexOfSelectedItem];
}

- (IBAction) pauseProgram: (id) sender {
    NSInteger checkedState = [menuPaused state];
    if(checkedState == NSOnState) {
        [menuPaused setState: NSOffState];
        [pause_step setEnabled: NO];
        isPaused = false;
    } else {
        [menuPaused setState: NSOnState];
        isPaused = true;
        [pause_step setEnabled: YES];
    }
}

- (IBAction) disableFilters: (id) sender {
    NSInteger checkedState = [disable_filters state];
    if(checkedState == NSOnState) {
        [disable_filters setState: NSOffState];
        // enable
        disableFilter = false;
    } else {
        [disable_filters setState: NSOnState];
        // disable
        disableFilter = true;
    }
}

- (IBAction) goto_Frame: (id) sender {
    int val = (int)[frame_slider integerValue];
    jumptoFrame(val);
}

- (IBAction) setGoto: (id) sender {
    NSInteger time_val = [frame_slider integerValue];
    NSString *str_val = [NSString stringWithFormat:@"Jump to Time: %f Seconds Frame #%d", time_val/ac::fps, (int)time_val];
    [goto_fr setStringValue: str_val];
}

- (IBAction) openGoto: (id) sender {
    if(total_frames != 0) {
        [goto_frame orderFront:self];
    } else {
        NSRunAlertPanel(@"Cannot jump to frame from webcam feed", @"Recording from Webcam", @"Ok", nil, nil);
    }
}

- (IBAction) pauseVideo: (id) sender {}

- (IBAction) changeFilterIndex: (id) sender {
    current_filterx = (int) [filter_selector indexOfSelectedItem];
}

- (IBAction) changeRGB: (id) sender {
    red = (int) [slider_red integerValue];
    green = (int) [slider_green integerValue];
    blue = (int) [slider_blue integerValue];
    [slider_red_pos setIntegerValue: red];
    [slider_green_pos setIntegerValue: green];
    [slider_blue_pos setIntegerValue: blue];
}

- (IBAction) changeReverse:(id)sender {
    reverse = (int)[rgb_box indexOfSelectedItem];
}

- (IBAction) changeNegate: (id) sender {
    negate = [check_box state] == NSOffState ? false : true;
}

- (IBAction) setNegative: (id) sender {
    NSInteger chkvalue = [negate_checked integerValue];
    if(chkvalue == NSOnState) ac::isNegative = true;
    else ac::isNegative = false;
}

- (IBAction) selectImage: (id) sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseDirectories:NO];
    [panel setCanChooseFiles: YES];
    [panel setAllowedFileTypes: [NSArray arrayWithObjects: @"jpg", @"png", nil]];
    if([panel runModal]) {
        NSString *file_name = [[panel URL] path];
        [image_combo addItemWithObjectValue: file_name];
    }
}
- (IBAction) setAsImage: (id) sender {
    if([image_combo indexOfSelectedItem] >= 0) {
    	NSString *current = [image_combo itemObjectValueAtIndex: [image_combo indexOfSelectedItem]];
    	blend_image = cv::imread([current UTF8String]);
    	blend_set = true;
        std::cout << "Image set..\n";
    }
}

- (IBAction) showCustom: (id) sender {
    [custom_window orderFront: self];
    
}
- (IBAction) showActivityLog: (id) sender {
    [window1 orderFront: self];
}
- (IBAction) showSelectImage: (id) sender {
    [image_select orderFront: self];
}
- (IBAction) showAlpha: (id) sender {
    [alpha_window orderFront: self];
}
- (IBAction) showPlugins: (id) sender {
    [plugin_window orderFront:self];
}


@end

void custom_filter(cv::Mat &frame) {
   // ac::isNegative = false;
   // ac::color_order = 0;
    NSInteger len = [custom_array count];
    for(NSInteger i = 0; i < len; ++i) {
        NSNumber *num = [custom_array objectAtIndex:i];
        NSInteger index = [num integerValue];
        ac::draw_func[(int)index](frame);
        //        [num release];
    }
}

void setSliders(int frame_count) {
    [frame_slider setMinValue: 0];
    [frame_slider setMaxValue: frame_count];
}

void ac::plugin(cv::Mat &frame) {
    if(plugin_loaded == false) return;
    int i = 0, z = 0;
    for(z = 0; z < frame.cols; ++z) {
        for(i = 0; i < frame.rows; ++i) {
            cv::Vec3b &buffer = frame.at<cv::Vec3b>(i, z);
            unsigned char pixels[] = { buffer[0], buffer[1], buffer[2] };
            (*pix)(z, i, pixels);
            buffer[0] = pixels[0];
            buffer[1] = pixels[1];
            buffer[2] = pixels[2];
        }
    }
    (*d)();
}
