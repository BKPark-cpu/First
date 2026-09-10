#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""다음 금융(finance.daum.net)에서 종목명으로 현재가와 전일비를 조회한다.

사용법:
    python3 stock_price.py 삼성전자          # 한 번 조회하고 종료
    python3 stock_price.py 삼성전자 카카오   # 여러 종목 연속 조회
    python3 stock_price.py                   # 대화형 모드 (종목명을 계속 입력)
    python3 stock_price.py --json 삼성전자   # JSON 으로 출력

필요 조건:
    pip install selenium          (Selenium 4.6+ 는 드라이버를 자동으로 받아온다)
    로컬에 Chrome 또는 Chromium 설치
    Chrome 경로를 직접 지정하려면 --browser-path / CHROME_BINARY 환경변수,
    chromedriver 경로는 --driver-path / CHROMEDRIVER 환경변수를 사용한다.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass, asdict
from urllib.parse import quote

from selenium import webdriver
from selenium.common.exceptions import (
    NoSuchElementException,
    TimeoutException,
    WebDriverException,
)
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

BASE_URL = "https://finance.daum.net/domestic/search"
SEARCH_URL = BASE_URL + "?q={query}"

# 사용자가 지정한 XPath
XPATH_SEARCH_BOX = '//*[@id="boxSearchbar"]/label'
XPATH_SEARCH_BUTTON = '//*[@id="btnSearchStock"]'
XPATH_NAME = '//*[@id="boxContents"]/div[2]/div/table/tbody/tr[1]/td[2]/a'
XPATH_PRICE = '//*[@id="boxContents"]/div[2]/div/table/tbody/tr[1]/td[3]/span'
XPATH_CHANGE = '//*[@id="boxContents"]/div[2]/div/table/tbody/tr[1]/td[4]/span'

# 상승/하락 표시에 쓰이는 클래스 조각 -> 부호
DIRECTION_MARKS = (
    (("rise", "up", "increase", "plus"), "▲"),
    (("fall", "down", "decrease", "minus"), "▼"),
)


class StockLookupError(Exception):
    """조회 실패."""


@dataclass
class Quote:
    query: str
    name: str
    price: str
    change: str
    direction: str
    url: str

    def as_text(self) -> str:
        change = f"{self.direction} {self.change}".strip()
        return f"{self.name}  현재가 {self.price}원  전일비 {change}"


def _normalize(text: str) -> str:
    return " ".join((text or "").split())


def _direction_from(class_name: str, text: str) -> str:
    """클래스명 또는 텍스트에서 상승/하락 부호를 뽑아낸다."""
    for mark in ("▲", "△", "+"):
        if mark in text:
            return "▲"
    for mark in ("▼", "▽", "-"):
        if mark in text:
            return "▼"
    lowered = (class_name or "").lower()
    for keywords, mark in DIRECTION_MARKS:
        if any(keyword in lowered for keyword in keywords):
            return mark
    return ""


def _strip_sign(text: str) -> str:
    """전일비 텍스트에서 화면용 부호 문자를 떼어낸다."""
    for mark in ("▲", "▼", "△", "▽", "+", "-"):
        text = text.replace(mark, " ")
    return _normalize(text)


class DaumFinance:
    """다음 금융 검색 페이지를 띄워 두고 종목을 반복 조회한다."""

    def __init__(self, headless: bool = True, timeout: float = 15.0,
                 browser_path: str | None = None, driver_path: str | None = None):
        self.timeout = timeout
        self.driver = self._make_driver(headless, browser_path, driver_path)

    @staticmethod
    def _make_driver(headless: bool, browser_path: str | None, driver_path: str | None):
        options = Options()
        if headless:
            options.add_argument("--headless=new")
        options.add_argument("--window-size=1400,1000")
        options.add_argument("--lang=ko-KR")
        options.add_argument("--disable-gpu")
        options.add_argument("--no-sandbox")
        options.add_argument("--disable-dev-shm-usage")
        options.add_argument(
            "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        )
        options.add_experimental_option("excludeSwitches", ["enable-automation"])
        binary = browser_path or os.environ.get("CHROME_BINARY")
        if binary:
            options.binary_location = binary
        driver = driver_path or os.environ.get("CHROMEDRIVER")
        service = Service(executable_path=driver) if driver else Service()
        return webdriver.Chrome(options=options, service=service)

    # --- 내부 동작 -------------------------------------------------------
    def _wait(self) -> WebDriverWait:
        return WebDriverWait(self.driver, self.timeout)

    def _find_search_input(self):
        """검색 입력창을 찾는다. 지정된 XPath 는 label 이므로 안쪽 input 을 쓴다."""
        try:
            label = self.driver.find_element(By.XPATH, XPATH_SEARCH_BOX)
        except NoSuchElementException:
            return self.driver.find_element(By.CSS_SELECTOR, "#boxSearchbar input")
        if label.tag_name.lower() in ("input", "textarea"):
            return label
        try:
            return label.find_element(By.XPATH, ".//input | .//textarea")
        except NoSuchElementException:
            return self.driver.find_element(By.CSS_SELECTOR, "#boxSearchbar input")

    def _search_by_form(self, name: str) -> bool:
        """검색창에 종목명을 입력하고 찾기 버튼을 누른다. 성공하면 True."""
        try:
            box = self._wait().until(lambda d: self._find_search_input())
            box.clear()
            box.send_keys(name)
            button = self._wait().until(
                EC.element_to_be_clickable((By.XPATH, XPATH_SEARCH_BUTTON))
            )
            button.click()
            return True
        except (TimeoutException, NoSuchElementException, WebDriverException):
            return False

    def _text_of(self, xpath: str, exclude: str | None = None) -> str:
        """해당 XPath 의 텍스트가 채워질 때까지 기다렸다가 읽는다.

        exclude 를 주면 그 값과 달라질 때까지 기다린다. 같은 화면에서 다시
        검색할 때 이전 종목의 값을 읽어 버리는 것을 막기 위한 것이다.
        """

        def ready(driver):
            text = _normalize(driver.find_element(By.XPATH, xpath).text)
            return text if text and text != exclude else False

        return self._wait().until(ready)

    def _first_row_name(self) -> str | None:
        """지금 화면에 떠 있는 첫 번째 결과의 종목명. 없으면 None."""
        try:
            return _normalize(self.driver.find_element(By.XPATH, XPATH_NAME).text) or None
        except (NoSuchElementException, WebDriverException):
            return None

    def _read_row(self, previous: str | None):
        """검색 결과 첫 줄에서 종목명, 현재가, 전일비 요소를 읽는다."""
        stock_name = self._text_of(XPATH_NAME, exclude=previous)
        price = self._text_of(XPATH_PRICE)
        change_el = self._wait().until(
            EC.presence_of_element_located((By.XPATH, XPATH_CHANGE))
        )
        return stock_name, price, change_el

    # --- 공개 API --------------------------------------------------------
    def lookup(self, name: str) -> Quote:
        name = name.strip()
        if not name:
            raise StockLookupError("종목명이 비어 있습니다.")

        url = SEARCH_URL.format(query=quote(name))
        not_found = f"'{name}' 검색 결과를 찾지 못했습니다. 종목명을 확인해 주세요."

        # 이미 검색 페이지에 있으면 검색창 + 찾기 버튼으로, 아니면 주소로 바로 이동한다.
        previous = (
            self._first_row_name()
            if self.driver.current_url.startswith(BASE_URL)
            else None
        )
        if previous == name:  # 같은 종목을 다시 조회하면 값이 그대로일 수 있다
            previous = None
        if not self.driver.current_url.startswith(BASE_URL) or not self._search_by_form(name):
            self.driver.get(url)
            previous = None

        try:
            stock_name, price, change_el = self._read_row(previous)
        except TimeoutException:
            if previous is None:
                raise StockLookupError(not_found) from None
            # 이전 결과가 그대로 남아 있으면 검색 결과 주소로 직접 이동해 다시 읽는다.
            self.driver.get(url)
            try:
                stock_name, price, change_el = self._read_row(None)
            except TimeoutException:
                raise StockLookupError(not_found) from None

        raw_change = _normalize(change_el.text)
        direction = _direction_from(change_el.get_attribute("class") or "", raw_change)
        current = self.driver.current_url or ""
        return Quote(
            query=name,
            name=stock_name,
            price=price,
            change=_strip_sign(raw_change) or "0",
            direction=direction,
            url=current if (quote(name) in current or name in current) else url,
        )

    def close(self) -> None:
        try:
            self.driver.quit()
        except WebDriverException:
            pass

    def __enter__(self) -> "DaumFinance":
        return self

    def __exit__(self, *exc) -> None:
        self.close()


def _report(quote_: Quote, as_json: bool) -> None:
    if as_json:
        print(json.dumps(asdict(quote_), ensure_ascii=False))
    else:
        print(quote_.as_text())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="다음 금융에서 종목명으로 현재가와 전일비를 조회합니다.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="예) python3 stock_price.py 삼성전자",
    )
    parser.add_argument("names", nargs="*", help="조회할 종목명 (없으면 대화형 모드)")
    parser.add_argument("--json", action="store_true", help="JSON 으로 출력")
    parser.add_argument(
        "--no-headless", dest="headless", action="store_false",
        help="브라우저 창을 띄워서 실행",
    )
    parser.add_argument("--timeout", type=float, default=15.0, help="대기 시간(초), 기본 15")
    parser.add_argument("--browser-path", help="Chrome/Chromium 실행 파일 경로")
    parser.add_argument("--driver-path", help="chromedriver 실행 파일 경로")
    args = parser.parse_args(argv)

    try:
        finance = DaumFinance(
            headless=args.headless,
            timeout=args.timeout,
            browser_path=args.browser_path,
            driver_path=args.driver_path,
        )
    except WebDriverException as exc:
        print(f"브라우저를 실행하지 못했습니다: {exc}", file=sys.stderr)
        return 2

    failed = False
    with finance:
        if args.names:
            for name in args.names:
                try:
                    _report(finance.lookup(name), args.json)
                except StockLookupError as exc:
                    print(exc, file=sys.stderr)
                    failed = True
            return 1 if failed else 0

        print("종목명을 입력하세요. (그냥 Enter 또는 q 를 누르면 종료)")
        while True:
            try:
                name = input("종목명> ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not name or name.lower() in ("q", "quit", "exit", "종료"):
                break
            try:
                _report(finance.lookup(name), args.json)
            except StockLookupError as exc:
                print(exc, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
