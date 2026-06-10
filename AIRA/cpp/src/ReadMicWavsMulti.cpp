#include <dirent.h>
#include <vector>
#include <algorithm>
#include <string>
#include <string.h>
#include <iostream>
#include <sstream>
#include <fstream>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/times.h>
#include <sys/types.h>
#include <sys/dir.h>
#include <sys/param.h>
#include <fcntl.h>
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <math.h>
#include <signal.h>

#include <sndfile.h>
#include <jack/jack.h>

#ifndef WIN32
#include <unistd.h>
#endif

using namespace std;

extern  int alphasort();

bool READ_ENDED = false;

unsigned int sr_pcm;

string app_name;
string channel_basename;
string wav_location;
vector<string> wavs_path;
vector<string> channel_names;

SNDFILE ** wavs;
SF_INFO *wavs_info;
int * wavs_i;

unsigned int channels;
unsigned int outputted_channels=0;
unsigned int outputted_channels_ids[100];

jack_port_t **output_port;
jack_client_t *client;

void millisleep(int milli){
  struct timespec st = {0};
  st.tv_sec = 0;
  st.tv_nsec = milli*1000000L;
  nanosleep(&st, NULL);
}

static void signal_handler ( int sig ){
  jack_client_close ( client );
  printf ("ReadMicWavsMulti: signal received, exiting ...\n" );
  exit ( 0 );
}

int process ( jack_nframes_t jack_buffer_size, void *arg ) {
  //Initializing I/O variables
  unsigned int i,j;
  double read_buffer[channels][jack_buffer_size];
  int read_count[channels];
  bool ended = false;
  
  //Writing to buffers
  jack_default_audio_sample_t *pDataOut[channels];
  for (j=0;j<channels;j++){
    pDataOut[j] = (jack_default_audio_sample_t*)jack_port_get_buffer ( output_port[j], jack_buffer_size );
    read_count[j] = sf_read_double(wavs[j],read_buffer[j],jack_buffer_size);
  }

  for (i=0;i<jack_buffer_size;i++){
    for (j=0;j<channels;j++){
      if (read_count[j] != jack_buffer_size && i >= read_count[j]){
        // Finished reading file
        // Completing the buffer with silence
        pDataOut[j][i] = 0.0;
        
        if (ended == false){
          cout << "ReadMicWavsMulti: Finished playing." << endl;
          ended = true;
        }
      }else{
        pDataOut[j][i] = (jack_default_audio_sample_t)read_buffer[j][i];
      }
      wavs_i[j]++;
    }
  }
  
  if (ended == true){
    cout << "ReadMicWavsMulti: Finished playing." << endl;
    READ_ENDED = true;
  }
  
  return 0;      
}

void jack_shutdown ( void *arg ){
  free ( output_port );
  exit ( 1 );
}

int file_select(const struct dirent *entry){
  char *ptr;
  //char *rindex(const char *s, char c);
  
  if ((strcmp(entry->d_name, ".")== 0) || (strcmp(entry->d_name, "..") == 0))
    return 0;
  
  /* Check for filename extensions */
  ptr = rindex((char *)entry->d_name, '.');
  if ((ptr != NULL) && (strcmp(ptr, ".wav") == 0))
    return 1;
  else
    return 0;
}

void usage(){
  cout << "Usage: ReadMicWavsMulti app_name channel_basename wav_location number_channels input_channel0 input_channel1 ... " << endl;
  cout << "\t app_name: name of JACK client where the outputs will connect to" << endl;
  cout << "\t channel_basename: basename of client inputs" << endl;
  cout << "\t wav_location: directory where wav_micX.wav's are located" << endl;
  cout << "\t number_channels: number of channels to connect to JACK client" << endl;
  cout << "\t input_channelX: channel number to connect X output" << endl;
}

int main ( int argc, char *argv[] ){
  if (argc < 5){
    usage();
    exit(1);
  }
  
  app_name = string(argv[1]);
  channel_basename = string(argv[2]);
  wav_location = string(argv[3]);
  channels = atoi(argv[4]);
  
  if (channels > 16){
    usage();
    exit(1);
  }
  
  cout << "ReadMicWavsMulti: Probing app   : " << app_name << endl;
  cout << "ReadMicWavsMulti: With " << channels << " channels with basename: " << channel_basename << "X" << endl;
  cout << "ReadMicWavsMulti: Reading from  : " << wav_location << endl;
  
  int i,j,k;
  
  /***********READING STUFF************/
  /* Obtain the WAV file list */
  wavs_i = (int *)malloc(channels * sizeof(int));
  wavs = (SNDFILE **)malloc(channels * sizeof(SNDFILE *));
  wavs_info = (SF_INFO *)malloc(channels * sizeof(SF_INFO));
  
  for (j=0; j<channels; j++){
    wavs_i[j] = 0;
    wavs_path.push_back(string(wav_location)+string("/wav_mic")+to_string(j+1)+string(".wav"));
    wavs_info[j].format = 0;
    
    cout << "ReadMicWavsMulti: Output " << j+1 <<" -> opening " << wavs_path[j] << endl;
    wavs[j] = sf_open (wavs_path[j].c_str(),SFM_READ,&wavs_info[j]);
    if (wavs[j] == NULL){
      printf ("ReadMicWavsMulti: Output %d -> Could not open '%s'\n", j+1, wavs_path[j].c_str()) ;
      exit(1);
    }
  }
  
  for (i=0,j=5; j<argc; j++,i++){
    int channel_id = atoi(argv[j]);
    outputted_channels_ids[i] = channel_id;
    //if channel_id is invalid ("0" or negative), it will be ignored by "jack_connect" later on
    channel_names.push_back(string(app_name)+string(":")+string(channel_basename)+to_string(channel_id));
    
    if(channel_id > channels || channel_id <= 0){
      printf("ReadMicWavsMulti: Output %d will not be connected; channel input %d is outside range [1,%d].\n",i+1, channel_id,channels);
    }else{
      printf("ReadMicWavsMulti: Output %d will be connected to channel input %d.\n",i+1,channel_id);
    }
  }
  
  /***********JACK STUFF************/
  const char *client_name = "ReadMicWavs";
  const char *server_name = NULL;
  jack_options_t options = JackNullOption;
  jack_status_t status;
  
  client = jack_client_open ( client_name, options, &status, server_name );
  if ( client == NULL ){
    printf ("ReadMicWavsMulti: jack_client_open() failed, "
              "status = 0x%2.0x\n", status );
    if ( status & JackServerFailed ){
        printf ("ReadMicWavsMulti: Unable to connect to JACK server\n" );
    }
    exit ( 1 );
  }
  if ( status & JackNameNotUnique ){
      client_name = jack_get_client_name ( client );
      printf ("ReadMicWavsMulti: unique name `%s' assigned\n", client_name );
  }
  jack_set_process_callback ( client, process, 0 );
  jack_on_shutdown ( client, jack_shutdown, 0 );
  sr_pcm = (unsigned int) jack_get_sample_rate (client);
  cout << "ReadMicWavsMulti: JACK sample rate : "<< sr_pcm << "." << endl;
  cout << "ReadMicWavsMulti: JACK buffer size : "<< jack_get_buffer_size(client) << "." << endl;
  
  output_port = ( jack_port_t** ) malloc ( channels*sizeof ( jack_port_t* ) );
  for ( i = 0; i < channels; i++ ){
    char port_name[16];
    sprintf ( port_name, "out_%d", i+1 );
    printf ("ReadMicWavsMulti: registering port %s \n", port_name);
    output_port[i] = jack_port_register ( client, port_name, JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput, 0 );
    if ( output_port[i] == NULL ){
      printf ("ReadMicWavsMulti: no more JACK ports available\n" );
      exit ( 1 );
    }
  }
  
  
  if ( jack_activate ( client ) ){
    printf ("ReadMicWavsMulti: cannot activate client" );
    exit ( 1 );
  }
  
  /* Connect app to these outputs */
  cout << "ReadMicWavsMulti: Connecting our outputs to " << app_name.c_str() << " inputs." << endl;
  for (i = 0; i < channels; i++){
    if (outputted_channels_ids[i] <= channels && outputted_channels_ids[i] > 0){
      cout << "ReadMicWavsMulti: Connecting " << jack_port_name (output_port[i]) << " to " << channel_names[i].c_str() << endl;
      if (jack_connect (client, jack_port_name (output_port[i]), channel_names[i].c_str()))
        printf ("ReadMicWavsMulti: cannot connect input ports.\n" );
    }
  }
  
  /* install a signal handler to properly quits jack client */
#ifdef WIN32
  signal ( SIGINT, signal_handler );
  signal ( SIGABRT, signal_handler );
  signal ( SIGTERM, signal_handler );
#else
  signal ( SIGQUIT, signal_handler );
  signal ( SIGTERM, signal_handler );
  signal ( SIGHUP, signal_handler );
  signal ( SIGINT, signal_handler );
#endif
  
  /* keep running until the transport stops */
  
  while (!READ_ENDED){
#ifdef WIN32
    Sleep ( 1000 );
#else
    sleep ( 1 );
#endif
  }
  
  free ( output_port );
  
  jack_client_close ( client );
  exit ( 0 );
}
