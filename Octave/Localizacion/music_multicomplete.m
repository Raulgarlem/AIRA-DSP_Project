%

doas = [-30 40];    %directional of arrival of both signals in degrees

d = 20;             %distance between microphones in meters

noise_w = 0.5;      %noise presence (between 0 and 1)

K = 200;        %signal size in samples, also frequency sampling
w = [0:(K/2), -(K/2)+1:-1]; 
                %frequency vector
%%%%%%%%

freq = [2 4]; %base frequency for signals

c = 343;            %speed of sound
fs = K;             %sampling frequency same as signal size (1 second)
t = (1:K)/K;        %time vector (1 second)

N = 3;              %number of microphones
r = 2;              %number of signals in signal sub-space

%original signals
s1 = sin(2*pi*freq(1)*t);
s2 = sin(2*pi*freq(2)*t);

s1_f = fft(s1);
s2_f = fft(s2);

%microphones
x = s1 + s2;
y = real(ifft(fft(s1).*exp(-i*2*pi*w*(d/c)*sin(doas(1)*pi/180)))) + real(ifft(fft(s2).*exp(-i*2*pi*w*(d/c)*sin(doas(2)*pi/180))));
z = real(ifft(fft(s1).*exp(-i*2*pi*w*(2*d/c)*sin(doas(1)*pi/180)))) + real(ifft(fft(s2).*exp(-i*2*pi*w*(2*d/c)*sin(doas(2)*pi/180))));

%adding noise
x = x + randn(1,K)*noise_w/10;
y = y + randn(1,K)*noise_w/10;
z = z + randn(1,K)*noise_w/10;

figure(1); plot(t,x,t,y,t,z); axis([min(t) max(t) -2 2]); title('Senales de entrada')

%data matrix with noise
X = [fft(x); fft(y); fft(z)];

%%% MUSIC
%define angles to look for orthogonality
angles = -90:0.1:90;
music_spectrum = zeros(r,length(angles));

%normally, you should do the next step for each appropriate frequency
%we're only doing it in the frequencies that most closely fit s1's and s2's frequency

this_ws = [3 , 5]; %since w(3) == 2 and w(5) == 4

for f = 1:length(this_ws)
  this_w = this_ws(f);

  this_X = X(:,this_w);

  %covariance matrix
  R = this_X*this_X'; %this matrix should be calculated using past windows,
                      %but for now using only current window

  %eigendecomposicion of covariance matrix
  % Q: vectors
  % D: values
  [Q,D] = eig(R);

  %sorting eigenvalues
  [D,I] = sort(diag(D),1,'descend');

  %sorting eigenvectors
  Q = Q(:,I);

  %getting signal eigenvectors
  Qs = Q(:,1:r);   %this could be done without knowing r

  %getting noise eigenvectors
  Qn = Q(:,r+1:N);


  %compute steering vectors corresponding to values in angles
  a1 = zeros(N,length(angles));
  a1(1,:) = ones(1,length(angles)); %first microphones is reference, no delay
  a1(2,:) = exp(-i*2*pi*w(this_w)*(d/c)*sin(angles*pi/180));   % second mic, delayed one distance
  a1(3,:) = exp(-i*2*pi*w(this_w)*(2*d/c)*sin(angles*pi/180));% third mic, delayed double distance

  %compute MUSIC spectrum
  for k=1:length(angles)
    music_spectrum(f,k)=abs(1/(a1(:,k)'*Qn*Qn'*a1(:,k)));
  end
end

figure(2)
%plotting all MUSIC spectra from all evaluated frequencies
plot(angles,music_spectrum');  title('MUSIC');
legend("2 Hz.", "4 Hz.")