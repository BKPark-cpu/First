# First

간단한 생활 도구 모음입니다. 각각 따로 실행합니다.

| 파일 | 무엇을 하나요 | 실행 방법 |
|---|---|---|
| `subway.py` | 서울 지하철 실시간 도착정보를 브라우저 화면에서 조회 | `python subway.py` |
| `stock_price.py` | 종목명으로 현재가·전일비 조회 (다음 금융) | `python stock_price.py 삼성전자` |
| `qr-code-generator.html` | 주소를 QR 코드로 변환 | 파일을 더블클릭 |

## 지하철 도착정보 (`subway.py`)

```bash
python subway.py
```

실행하면 내 PC 안에서만 도는 작은 서버가 뜨고 브라우저가 자동으로 열립니다.
역 이름을 넣고 **조회**를 누르면 그 역에 곧 들어올 열차가 노선별로 표시됩니다.
창을 닫으려면 실행한 명령창에서 `Ctrl+C` 를 누르세요.

- 파이썬만 있으면 됩니다. 따로 설치할 부품이 없습니다.
- 처음 한 번 **서울 열린데이터광장 인증키**를 화면에서 입력하면
  `subway_key.txt` 파일로 저장되어 다음부터는 묻지 않습니다.
  ([인증키 발급](https://data.seoul.go.kr) → 실시간 지하철 도착정보)
- 인증키는 비밀번호와 같은 값이라 코드에 넣지 않았고,
  `subway_key.txt` 는 `.gitignore` 에 있어 GitHub 에 올라가지 않습니다.
- 역 이름은 `서울` / `서울역` 둘 다 됩니다.

## 주식 시세 (`stock_price.py`)

```bash
pip install -r requirements.txt   # 처음 한 번만
python stock_price.py 삼성전자
python stock_price.py             # 대화형: 종목명을 계속 입력, q 로 종료
```

크롬 브라우저를 자동으로 움직여 다음 금융에서 값을 읽어 옵니다.
`--no-headless` 를 붙이면 브라우저 창이 보이는 상태로 실행됩니다.
