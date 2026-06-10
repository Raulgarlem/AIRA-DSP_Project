%
doa = 30;     %directional of arrival of the signal in degrees
d = 20;         %distance between microphones in meters

noise_w = 0.0;    %noise presence (between 0 and 1)

K = 200;        %signal size in samples, also frequency sampling
w = [0:(K/2), -(K/2)+1:-1]; 
                %frequency vector
%%%%%%%%

freq = 2;     %base frequency of signal of interest (SOI)

c = 343;        %speed of sound
t = (1:K)/K;    %time vector (1 second)

r = 1;          %number of signals in signal sub-space
N = 2;          %number of microphones


s1 = sin(2*pi*freq*t);  %defining the original SOI

x = s1; %first mic, steering vector equal to 1, no delay
y = real(ifft(fft(s1).*exp(-i*2*pi*w*(d/c)*sin(doa*pi/180))));   % second mic, delayed one distance

%adding noise
x = x + randn(1,K)*noise_w/10;
y = y + randn(1,K)*noise_w/10;

figure(1); plot(t,x,t,y); axis([min(t) max(t) -1 1]); title('Senales de entrada')

%data matrix
X = [fft(x); fft(y)];

%%% MUSIC
%define angles to look for orthogonality
angles = -90:0.1:90;
music_spectrum = zeros(1,length(angles));

%normally, you should do the next step for each appropriate frequency
%we're only doing it in the frequency that most closely fits s1's frequency

this_w = 3; %since w(3) == 2

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

%compute MUSIC spectrum
for k=1:length(angles)
  music_spectrum(k)=abs(1/(a1(:,k)'*Qn*Qn'*a1(:,k)));
end

figure(2)
plot(angles,music_spectrum);  title('MUSIC')
