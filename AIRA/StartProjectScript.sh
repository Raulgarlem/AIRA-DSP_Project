# asumiendo que tenemos la siguiente estructura
# .
#   jack_in_to_out #algoritmo
# ./baudline
#   baudline_jack #ejecutable de baudline
# ./aira
#   corpus48000 # directorio de aira
#   ReadMicWavs # ejectubal de ReadMicWavs

# correr con:
#   bash script.sh

#corremos algoritmo en el fondo (&)
./build/jack_in_to_out &
jackpid=$!
sleep 1

#lo desconectamos de los microfonos
jack_disconnect system:capture_1 in_to_out:input_1

#corremos baudline en el fondo (&)
./baudline/baudline_jack -jack -channels 2 -pause &
baudlinepid=$!
sleep 1

#corremos ReadMicWavs en el fondo (&)
./build/ReadMicWavs in_to_out input_ ../data/corpus48000/clean-3source 2 &
rmwpid=$!
sleep 1

#conectamos la salide ReadMicWavs y baudline
jack_connect ReadMicWavs:out_1 baudline:in_1


#nos esperamos una cierta cantidad de tiempo para que todo funcione
sleep 5

#cerramos todo
kill $jackpid
kill $baudlinepid
kill $rmwpid
